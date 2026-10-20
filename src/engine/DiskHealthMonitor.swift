import Foundation
import Darwin
import Combine

// MARK: - Core Health Monitor Engine

final class DiskHealthMonitor: ObservableObject {
    static let shared = DiskHealthMonitor()

    @Published private(set) var currentSnapshot: DiskHealthSnapshot?
    @Published private(set) var isVerifyingVolume: Bool = false
    private var isVerifyingInternal: Bool = false

    private let engineLock = NSRecursiveLock()
    private var state: DiskPersistentState
    private var previousDriveKey: String = ""
    private var previousBytesRead: UInt64 = 0
    private var previousBytesWritten: UInt64 = 0
    private var previousSampleTime: TimeInterval = 0
    private var lastCanaryRunTime: TimeInterval = 0
    private var cachedCanaryOk: Bool = true
    private var cachedCanaryLatencyMs: Double = 0.0
    private var cachedCanaryError: String = ""
    private var lastWakeTime: TimeInterval = 0
    private(set) var isSystemSleeping: Bool = false
    private var recentTemperatureSamples: [String: [(timestamp: TimeInterval, tempC: Int)]] = [:]

    private init() {
        self.state = DiskHealthMonitor.loadState()
    }

    static func evaluateThermalSpike(samples: [(timestamp: TimeInterval, tempC: Int)], currentTempC: Int, nowTs: TimeInterval) -> (updatedSamples: [(timestamp: TimeInterval, tempC: Int)], issue: HealthIssue?, scorePenalty: Int) {
        var window = samples.filter { (nowTs - $0.timestamp) <= 180.0 && $0.timestamp <= nowTs }
        if let last = window.last, (nowTs - last.timestamp) < 2.0 && last.tempC == currentTempC {
            // Avoid unbounded sample growth when evaluateHealth is invoked multiple times per second
        } else {
            window.append((timestamp: nowTs, tempC: currentTempC))
        }
        guard let minSample = window.min(by: { $0.tempC < $1.tempC }) else {
            return (window, nil, 0)
        }
        let delta = currentTempC - minSample.tempC
        let dt = max(1.0, nowTs - minSample.timestamp)
        if delta >= 8 && currentTempC >= 45 {
            let ratePerMin = Double(delta) / (dt / 60.0)
            let issue = HealthIssue(
                code: "TEMP_RAPID_RISE",
                severity: .warning,
                title: "Rapid Temperature Spike Detected",
                detail: String(format: "Drive temperature rose +%d°C in %.0fs (+%.1f°C/min to %d°C).", delta, dt, ratePerMin, currentTempC)
            )
            return (window, issue, 10)
        }
        return (window, nil, 0)
    }

    static func isNonCorruptionVerifyFailure(_ result: String) -> Bool {
        let lower = result.lowercased()
        return lower.contains("-69863") ||
               lower.contains("insufficient privileges") ||
               lower.contains("permission denied") ||
               lower.contains("not permitted") ||
               lower.contains("operation not permitted") ||
               lower.contains("-69888") ||
               lower.contains("couldn't unmount") ||
               lower.contains("could not unmount") ||
               lower.contains("couldn't be unmounted") ||
               lower.contains("could not be unmounted") ||
               lower.contains("unable to unmount") ||
               lower.contains("resource busy") ||
               lower.contains("volume is busy")
    }

    static func classifyVolumeVerificationOutput(terminationStatus: Int32, output: String, didTimeout: Bool, timeStr: String) -> (isHealthy: Bool, isSkipped: Bool, summary: String) {
        if didTimeout {
            return (true, true, "Skipped (\(timeStr)): Verification timed out after 180s")
        }
        let passed = (terminationStatus == 0) &&
            (output.contains("appears to be OK") ||
             output.contains("Finished file system verification") ||
             output.contains("File system check exit code is 0"))
        if passed {
            return (true, false, "Verified OK (\(timeStr))")
        }
        if isNonCorruptionVerifyFailure(output) {
            let lower = output.lowercased()
            if output.contains("-69863") || lower.contains("insufficient privileges") || lower.contains("permission denied") || lower.contains("not permitted") {
                return (true, true, "Skipped (\(timeStr)): Requires administrator privileges (-69863)")
            }
            return (true, true, "Skipped (\(timeStr)): Volume busy / in use")
        }
        let lastLines = output.components(separatedBy: .newlines).filter { !$0.isEmpty }.suffix(2).joined(separator: " | ")
        let detail = lastLines.isEmpty ? "Exit code \(terminationStatus)" : lastLines
        return (false, false, "Failed (\(timeStr)): \(detail)")
    }

    static func loadState() -> DiskPersistentState {
        let path = ConfigManager.shared.stateFilePath
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           var decoded = try? JSONDecoder().decode(DiskPersistentState.self, from: data) {
            var migrated = false
            for (k, var d) in decoded.drives {
                if !d.lastVerifyOk && isNonCorruptionVerifyFailure(d.lastVerifyResult) {
                    d.lastVerifyOk = true
                    d.lastVerifyResult = "Skipped: Requires administrator privileges (-69863)"
                    if d.lastOverallSeverity == HealthSeverity.critical.rawValue {
                        d.lastOverallSeverity = HealthSeverity.healthy.rawValue
                    }
                    decoded.drives[k] = d
                    migrated = true
                }
                if d.lastVerifyOk {
                    let verifyAlertKey = "\(k):VOLUME_VERIFY_FAILED"
                    if decoded.lastAlertTimestampByCode.removeValue(forKey: verifyAlertKey) != nil {
                        migrated = true
                    }
                }
                if d.lastVerifyResult == "Not run yet" && d.lastVerifyTimestamp > 0 {
                    d.lastVerifyTimestamp = 0
                    decoded.drives[k] = d
                    migrated = true
                }
            }
            if decoded.lastAlertTimestampByCode.removeValue(forKey: "VOLUME_VERIFY_FAILED") != nil {
                migrated = true
            }
            if migrated {
                if decoded.lastOverallSeverity == HealthSeverity.critical.rawValue &&
                   !decoded.drives.values.contains(where: { $0.lastOverallSeverity == HealthSeverity.critical.rawValue }) {
                    decoded.lastOverallSeverity = HealthSeverity.healthy.rawValue
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let outData = try? encoder.encode(decoded) {
                    try? outData.write(to: URL(fileURLWithPath: path), options: .atomic)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
                }
            }
            return decoded
        }
        return DiskPersistentState()
    }

    private func saveStateLocked() {
        let path = ConfigManager.shared.stateFilePath
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(state) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }

    func noteSystemWillSleep() {
        engineLock.lock()
        isSystemSleeping = true
        previousSampleTime = 0
        engineLock.unlock()
        ConfigManager.shared.log("System entering sleep; pausing telemetry deltas.")
    }

    func noteSystemDidWake(at timestamp: TimeInterval = Date().timeIntervalSince1970) {
        engineLock.lock()
        isSystemSleeping = false
        lastWakeTime = timestamp
        previousSampleTime = 0
        lastCanaryRunTime = 0
        engineLock.unlock()
        ConfigManager.shared.log("System woke from sleep; applying 8s hardware settle grace period.")
    }

    var dailySummaryEnabled: Bool {
        get {
            engineLock.lock()
            defer { engineLock.unlock() }
            return state.dailySummaryEnabled
        }
        set {
            engineLock.lock()
            state.dailySummaryEnabled = newValue
            saveStateLocked()
            engineLock.unlock()
        }
    }

    var persistentState: DiskPersistentState {
        engineLock.lock()
        defer { engineLock.unlock() }
        return state
    }

    func mutateStateForTesting(_ block: (inout DiskPersistentState) -> Void) {
        engineLock.lock()
        defer { engineLock.unlock() }
        block(&self.state)
        saveStateLocked()
    }

    func clearCurrentSnapshotForTesting() {
        engineLock.lock()
        defer { engineLock.unlock() }
        self.currentSnapshot = nil
    }

    func setMonitoredTarget(volumePath: String?, deviceQuery: String?) {
        ConfigManager.shared.updateTarget(volumePath: volumePath, deviceQuery: deviceQuery)
        engineLock.lock()
        let newTarget = volumePath ?? deviceQuery ?? "auto"
        let targetChanged = (state.monitoredTarget != newTarget)
        state.monitoredTarget = newTarget
        if targetChanged {
            state.lastOverallSeverity = HealthSeverity.healthy.rawValue
            previousDriveKey = ""
            previousBytesRead = 0
            previousBytesWritten = 0
            previousSampleTime = 0
            lastCanaryRunTime = 0
        }
        saveStateLocked()
        engineLock.unlock()
    }

    func resetBaselines() {
        engineLock.lock()
        defer { engineLock.unlock() }
        let oldTarget = self.state.monitoredTarget
        let oldDaily = self.state.dailySummaryEnabled
        if let snap = self.currentSnapshot {
            let key = !snap.serialNumber.isEmpty ? snap.serialNumber : (!snap.bsdName.isEmpty ? snap.bsdName : (snap.mountPoint.isEmpty ? "default" : snap.mountPoint))
            self.state.updateDriveState(key: key) { d in
                d.bsdName = snap.bsdName
                d.serialNumber = snap.serialNumber
                d.peakTemperatureCelsius = snap.temperatureCelsius
                d.baselineUnsafeShutdowns = snap.unsafeShutdowns
                d.baselineMediaErrors = snap.mediaErrors
                d.baselineErrorLogEntries = snap.errorInfoLogEntries
                d.baselineIoReadErrors = snap.errorsRead
                d.baselineIoWriteErrors = snap.errorsWritten
                d.baselineIoReadRetries = snap.retriesRead
                d.baselineIoWriteRetries = snap.retriesWritten
            }
        } else {
            for k in Array(self.state.drives.keys) {
                self.state.updateDriveState(key: k) { d in
                    d.baselineUnsafeShutdowns = nil
                    d.baselineMediaErrors = nil
                    d.baselineErrorLogEntries = nil
                    d.baselineIoReadErrors = nil
                    d.baselineIoWriteErrors = nil
                    d.baselineIoReadRetries = nil
                    d.baselineIoWriteRetries = nil
                }
            }
            self.state.monitoredTarget = oldTarget
            self.state.dailySummaryEnabled = oldDaily
        }
        for k in Array(self.state.drives.keys) {
            self.state.updateDriveState(key: k) {
                $0.lastVerifyOk = true
                if !$0.lastVerifyResult.starts(with: "Verified OK") {
                    $0.lastVerifyResult = "Not run yet"
                    $0.lastVerifyTimestamp = 0
                }
                $0.lastOverallSeverity = HealthSeverity.healthy.rawValue
            }
        }
        self.state.lastOverallSeverity = HealthSeverity.healthy.rawValue
        self.state.lastAlertTimestampByCode.removeAll()
        self.recentTemperatureSamples.removeAll()
        saveStateLocked()
        ConfigManager.shared.log("Persistent baselines and health state reset.")
    }

    private func runCanaryCheck(targetMount: String, force: Bool) -> (Bool, Double, String) {
        let now = Date().timeIntervalSince1970
        if !force && (now - lastCanaryRunTime) < 300 && lastCanaryRunTime > 0 {
            return (cachedCanaryOk, cachedCanaryLatencyMs, cachedCanaryError)
        }

        var result = performSingleCanaryPass(targetMount: targetMount)
        if !result.0 || result.1 > 300.0 {
            usleep(50_000) // 50ms settle before retry pass
            let secondPass = performSingleCanaryPass(targetMount: targetMount)
            if secondPass.0 || !result.0 {
                result = secondPass
            }
        }

        cachedCanaryOk = result.0
        cachedCanaryLatencyMs = result.1
        cachedCanaryError = result.2
        lastCanaryRunTime = now
        return result
    }

    private func performSingleCanaryPass(targetMount: String) -> (Bool, Double, String) {
        // On sealed macOS root volume ("/"), probe via /System/Volumes/Data/private/tmp if writable,
        // avoiding guaranteed EROFS on "/.disk_health_canary"
        let effectiveDir: String
        if targetMount == "/" && FileManager.default.isWritableFile(atPath: "/System/Volumes/Data/private/tmp") {
            effectiveDir = "/System/Volumes/Data/private/tmp"
        } else {
            effectiveDir = targetMount
        }

        let canaryPath = (effectiveDir as NSString).appendingPathComponent(".disk_health_canary_\(getuid())")
        let token = "DISK_HEALTH_CANARY_\(UUID().uuidString)\n"
        guard let data = token.data(using: .utf8) else {
            return (false, 0, "Encoding error")
        }

        let start = DispatchTime.now()
        // Use O_NOFOLLOW to prevent symlink truncation attacks and O_CLOEXEC to prevent fd inheritance
        let fd = open(canaryPath, O_CREAT | O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd < 0 {
            let errCode = errno
            if errCode == EPERM || errCode == EACCES || errCode == EROFS {
                // Fallback to active read/directory probe on the mount directory itself
                let readStart = DispatchTime.now()
                guard let dir = opendir(targetMount) else {
                    let dirErr = String(cString: strerror(errno))
                    return (false, 0, "opendir failed: \(dirErr)")
                }
                var entryCount = 0
                while let entry = readdir(dir) {
                    entryCount += 1
                    _ = entry.pointee.d_ino
                }
                closedir(dir)
                if entryCount == 0 {
                    return (false, 0, "readdir returned 0 entries")
                }
                let elapsedNs = DispatchTime.now().uptimeNanoseconds - readStart.uptimeNanoseconds
                let elapsedMs = Double(elapsedNs) / 1_000_000.0
                return (true, elapsedMs, "")
            }
            let errStr = String(cString: strerror(errCode))
            return (false, 0, "open write failed: \(errStr)")
        }

        let written = data.withUnsafeBytes { ptr -> Int in
            guard let base = ptr.baseAddress else { return -1 }
            return write(fd, base, data.count)
        }
        if written != data.count {
            let errStr = String(cString: strerror(errno))
            close(fd)
            unlink(canaryPath)
            return (false, 0, "write failed: \(errStr)")
        }

        if fsync(fd) != 0 {
            let errStr = String(cString: strerror(errno))
            close(fd)
            unlink(canaryPath)
            return (false, 0, "fsync failed: \(errStr)")
        }
        close(fd)

        guard let readBack = try? String(contentsOfFile: canaryPath, encoding: .utf8), readBack == token else {
            unlink(canaryPath)
            return (false, 0, "readback verification mismatch")
        }

        unlink(canaryPath)
        let elapsedNs = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        let elapsedMs = Double(elapsedNs) / 1_000_000.0
        return (true, elapsedMs, "")
    }

    @discardableResult
    func evaluateHealth(forceCanary: Bool = false, allowNotifications: Bool = true) -> DiskHealthSnapshot {
        engineLock.lock()
        defer { engineLock.unlock() }

        let now = Date()
        let nowTs = now.timeIntervalSince1970
        let formattedTime = isoTimestampFormatter.string(from: now)
        let formattedShortTime = shortTimeFormatter.string(from: now)
        let cfg = ConfigManager.shared.currentConfig

        // 1. Determine Target Mount & Hardware Query
        var targetMount = cfg.targetVolumePath ?? ""
        let targetQuery = cfg.targetDeviceQuery ?? ""

        // 2. Hardware IOKit Bridge Query
        var hw = DiskHardwareMetrics()
        let queryToPass = !targetMount.isEmpty ? targetMount : (!targetQuery.isEmpty ? targetQuery : "auto")
        DiskReadHardwareMetrics(queryToPass, &hw)

        let vendorName = hw.found ? cStringToSwift(hw.vendorName) : "Generic"
        let productName = hw.found ? cStringToSwift(hw.productName) : "Storage Device"
        let productRevision = hw.found ? cStringToSwift(hw.productRevision) : ""
        let bsdName = hw.found ? cStringToSwift(hw.bsdName) : ""
        let serialNumber = hw.found ? cStringToSwift(hw.serialNumber) : ""
        let interconnect = hw.found ? cStringToSwift(hw.interconnectType) : "Storage"
        let protocolType = hw.found ? cStringToSwift(hw.protocolType) : ""
        let linkSpeedFormatted = formatLinkSpeed(hw.linkSpeedBps, interconnect: interconnect)

        // 3. Resolve Mount Point for this Hardware Device if targetMount is not explicitly set
        if targetMount.isEmpty && hw.found && !bsdName.isEmpty {
            var cMountPath = [CChar](repeating: 0, count: 512)
            if DiskFindMountForBlockDevice(bsdName, &cMountPath, 512) {
                targetMount = String(cString: cMountPath)
            }
        }

        // 4. Mount & Filesystem Inspection via statfs
        var isMounted = false
        var mountPoint = ""
        var fsType = ""
        var isReadOnly = false
        var totalBytes: UInt64 = 0
        var freeBytes: UInt64 = 0
        var purgeableBytes: UInt64 = 0
        var usedBytes: UInt64 = 0
        var usedPercent: Double = 0.0

        let mountToInspect = !targetMount.isEmpty ? targetMount : (!targetQuery.isEmpty && targetQuery.starts(with: "/") ? targetQuery : "")
        if !mountToInspect.isEmpty {
            var sfs = statfs()
            if statfs(mountToInspect, &sfs) == 0 {
                let resolvedMountPoint = (cStringToSwift(sfs.f_mntonname) as NSString).standardizingPath
                let resolvedInspect = (mountToInspect as NSString).standardizingPath
                fsType = cStringToSwift(sfs.f_fstypename)

                // If inspecting a path under /Volumes/..., its resolved mount point must also be under /Volumes/
                // (not "/" or "/System/Volumes/Data", which happens when /Volumes/Foo is an unmounted stub directory).
                let isValidMatch: Bool
                if resolvedInspect.hasPrefix("/Volumes/") {
                    isValidMatch = (resolvedMountPoint == resolvedInspect) ||
                                   (resolvedMountPoint.hasPrefix("/Volumes/") && resolvedInspect.hasPrefix(resolvedMountPoint + "/"))
                } else {
                    isValidMatch = (resolvedMountPoint == resolvedInspect) ||
                                   (resolvedMountPoint == "/" || resolvedMountPoint == "/System/Volumes/Data") ||
                                   resolvedInspect.hasPrefix(resolvedMountPoint + "/")
                }

                if isValidMatch {
                    // For /System/Volumes/Data firmlinks (e.g. /Users, /Applications), normalize mountPoint to "/"
                    mountPoint = (resolvedMountPoint == "/System/Volumes/Data" && !resolvedInspect.hasPrefix("/System/Volumes/Data")) ? "/" : resolvedMountPoint
                    isMounted = true
                    isReadOnly = (sfs.f_flags & UInt32(MNT_RDONLY)) != 0
                    let bsize = UInt64(sfs.f_bsize)
                    totalBytes = UInt64(sfs.f_blocks) * bsize
                    let rawFreeBytes = UInt64(sfs.f_bavail) * bsize
                    var effectiveFreeBytes = rawFreeBytes

                    let mountURL = URL(fileURLWithPath: mountPoint)
                    if let vals = try? mountURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
                       let importantFree = vals.volumeAvailableCapacityForImportantUsage,
                       importantFree > 0 {
                        let importantU64 = UInt64(importantFree)
                        if importantU64 > rawFreeBytes && importantU64 <= totalBytes {
                            purgeableBytes = importantU64 - rawFreeBytes
                            effectiveFreeBytes = importantU64
                        }
                    }

                    freeBytes = effectiveFreeBytes
                    usedBytes = totalBytes > freeBytes ? (totalBytes - freeBytes) : 0
                    usedPercent = totalBytes > 0 ? (Double(usedBytes) / Double(totalBytes) * 100.0) : 0.0
                }
            }
        }

        // 4. Required Subpaths Check (if user configured any)
        var subpathsStatus: [String: Bool] = [:]
        for subpath in cfg.requiredSubpaths {
            let cleanSub = subpath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            guard !cleanSub.isEmpty, !cleanSub.components(separatedBy: "/").contains("..") else {
                subpathsStatus[subpath] = false
                continue
            }
            let fullSubpath = (mountPoint as NSString).appendingPathComponent(cleanSub)
            var isDir: ObjCBool = false
            let exists = isMounted && FileManager.default.fileExists(atPath: fullSubpath, isDirectory: &isDir)
            subpathsStatus[subpath] = exists
        }

        let driveKey = !serialNumber.isEmpty
            ? serialNumber
            : (!bsdName.isEmpty ? bsdName : (!targetMount.isEmpty ? targetMount : (!targetQuery.isEmpty ? targetQuery : "default")))
        if driveKey != previousDriveKey {
            if !previousDriveKey.isEmpty {
                state.lastOverallSeverity = HealthSeverity.healthy.rawValue
            }
            previousDriveKey = driveKey
            previousBytesRead = 0
            previousBytesWritten = 0
            previousSampleTime = 0
            lastCanaryRunTime = 0
        }

        // 5. Active I/O Canary Probe
        var canaryOk = false
        var canaryLatencyMs = 0.0
        var canaryError = isMounted ? "Canary disabled" : "Volume not mounted"
        if isMounted && cfg.enableActiveCanary {
            if isSystemSleeping {
                canaryOk = true
                canaryError = "Suppressed while system is sleeping"
            } else if !isReadOnly || mountPoint == "/" {
                (canaryOk, canaryLatencyMs, canaryError) = runCanaryCheck(targetMount: mountPoint, force: forceCanary)
            } else {
                canaryOk = false
                canaryError = "Volume is mounted Read-Only"
            }
        }

        // 6. Throughput & Latency Calculations
        var readMBps = 0.0
        var writeMBps = 0.0
        if hw.statsValid {
            if previousSampleTime > 0 && nowTs > previousSampleTime {
                let dt = nowTs - previousSampleTime
                if hw.bytesRead >= previousBytesRead {
                    readMBps = Double(hw.bytesRead - previousBytesRead) / (1_000_000.0 * dt)
                }
                if hw.bytesWritten >= previousBytesWritten {
                    writeMBps = Double(hw.bytesWritten - previousBytesWritten) / (1_000_000.0 * dt)
                }
            }
            previousBytesRead = hw.bytesRead
            previousBytesWritten = hw.bytesWritten
            previousSampleTime = nowTs
        }

        let avgReadLatMs = (hw.statsValid && hw.operationsRead > 0)
            ? (Double(hw.totalTimeReadNs) / Double(hw.operationsRead) / 1_000_000.0)
            : 0.0
        let avgWriteLatMs = (hw.statsValid && hw.operationsWritten > 0)
            ? (Double(hw.totalTimeWriteNs) / Double(hw.operationsWritten) / 1_000_000.0)
            : 0.0

        // 7. Update Peak Temp & Baselines for this specific physical drive
        var driveState = state.getDriveState(key: driveKey, bsdName: bsdName, serial: serialNumber)

        let tempC = Int(hw.temperatureCelsius)
        if hw.smartValid && tempC > driveState.peakTemperatureCelsius {
            driveState.peakTemperatureCelsius = tempC
        }
        if hw.smartValid {
            if driveState.baselineUnsafeShutdowns == nil { driveState.baselineUnsafeShutdowns = hw.unsafeShutdowns }
            if driveState.baselineMediaErrors == nil { driveState.baselineMediaErrors = 0 }
            if driveState.baselineErrorLogEntries == nil { driveState.baselineErrorLogEntries = hw.errorInfoLogEntries }
        }
        if hw.statsValid {
            if driveState.baselineIoReadErrors == nil { driveState.baselineIoReadErrors = 0 }
            if driveState.baselineIoWriteErrors == nil { driveState.baselineIoWriteErrors = 0 }
            if driveState.baselineIoReadRetries == nil { driveState.baselineIoReadRetries = hw.retriesRead }
            if driveState.baselineIoWriteRetries == nil { driveState.baselineIoWriteRetries = hw.retriesWritten }
        }
        state.drives[driveKey] = driveState

        // 8. Health Evaluation Rules Engine
        var issues: [HealthIssue] = []
        var score = 100
        let inWakeGrace = isSystemSleeping || (lastWakeTime > 0 && (nowTs - lastWakeTime < 8.0))

        // Rule 1: Hardware Presence
        if !hw.found {
            if inWakeGrace {
                ConfigManager.shared.log("Hardware presence not confirmed during wake grace period (8s); suppressing false alert.")
            } else {
                issues.append(HealthIssue(
                    code: "HW_DISCONNECTED",
                    severity: .critical,
                    title: "Storage Hardware Disconnected",
                    detail: "Target device was not detected on macOS IOKit storage buses."
                ))
                score -= 60
            }
        }

        // Rule 2: Volume Mount Status
        if !mountToInspect.isEmpty && !isMounted {
            if inWakeGrace {
                ConfigManager.shared.log("Volume unmounted status during wake grace period (8s); suppressing false alert.")
            } else {
                issues.append(HealthIssue(
                    code: "VOLUME_UNMOUNTED",
                    severity: .critical,
                    title: "Volume Unmounted",
                    detail: "Volume \(mountToInspect) is not mounted."
                ))
                score -= 50
            }
        } else if isMounted {
            // Rule 3: Read-Only Mount (excluding sealed macOS root filesystem)
            if isReadOnly && mountPoint != "/" {
                issues.append(HealthIssue(
                    code: "VOLUME_READONLY",
                    severity: .critical,
                    title: "Volume Mounted Read-Only",
                    detail: "Volume \(mountPoint) is mounted in read-only mode (filesystem journal fault or protection)."
                ))
                score -= 45
            }

            // Rule 4: Required Subpaths Check
            for (subpath, exists) in subpathsStatus {
                if !exists {
                    issues.append(HealthIssue(
                        code: "REQUIRED_PATH_MISSING",
                        severity: .critical,
                        title: "Required Subpath Inaccessible",
                        detail: "Configured path '\(subpath)' on \(mountPoint) could not be accessed."
                    ))
                    score -= 35
                }
            }

            // Rule 5: Active Canary Probe
            if cfg.enableActiveCanary {
                if inWakeGrace {
                    ConfigManager.shared.log("Canary probe issue suppressed during wake grace period (8s).")
                } else if !canaryOk {
                    issues.append(HealthIssue(
                        code: "CANARY_IO_FAILED",
                        severity: .critical,
                        title: "Filesystem Canary Probe Failed",
                        detail: "Canary write/sync/read probe on \(mountPoint) failed: \(canaryError)"
                    ))
                    score -= 40
                } else if canaryLatencyMs > 300.0 {
                    issues.append(HealthIssue(
                        code: "CANARY_HIGH_LATENCY",
                        severity: .warning,
                        title: "High Filesystem Latency",
                        detail: String(format: "Canary probe took %.1f ms (> 300 ms).", canaryLatencyMs)
                    ))
                    score -= 10
                }
            }

            // Rule 6: Free Space Check
            let freeGB = Double(freeBytes) / 1_000_000_000.0
            let totalGB = Double(totalBytes) / 1_000_000_000.0
            let effectiveCriticalGB = totalGB > 0 ? min(cfg.minFreeSpaceCriticalGB, totalGB * 0.05) : cfg.minFreeSpaceCriticalGB
            let effectiveWarningGB = totalGB > 0 ? min(cfg.minFreeSpaceWarningGB, totalGB * 0.10) : cfg.minFreeSpaceWarningGB

            if usedPercent >= cfg.diskUsedCriticalPercent || freeGB < effectiveCriticalGB {
                issues.append(HealthIssue(
                    code: "DISK_SPACE_CRITICAL",
                    severity: .critical,
                    title: "Critically Low Disk Space",
                    detail: String(format: "Only %.1f GB free (%.1f%% used on %@).", freeGB, usedPercent, mountPoint)
                ))
                score -= 25
            } else if usedPercent >= cfg.diskUsedWarningPercent || freeGB < effectiveWarningGB {
                issues.append(HealthIssue(
                    code: "DISK_SPACE_WARNING",
                    severity: .warning,
                    title: "Low Disk Space Warning",
                    detail: String(format: "%.1f GB free (%.1f%% used on %@).", freeGB, usedPercent, mountPoint)
                ))
                score -= 10
            }
        }

        // Rule 7: Link Speed Degraded
        if hw.found && cfg.minExpectedUsbSpeedBps > 0 && hw.linkSpeedBps > 0 && hw.linkSpeedBps < cfg.minExpectedUsbSpeedBps {
            issues.append(HealthIssue(
                code: "USB_LINK_DEGRADED",
                severity: .warning,
                title: "Link Speed Degraded",
                detail: "Drive negotiated at \(linkSpeedFormatted) instead of expected \(formatLinkSpeed(cfg.minExpectedUsbSpeedBps, interconnect: interconnect)). Check cable or port."
            ))
            score -= 15
        }

        // SMART Rules
        if hw.smartValid {
            // Rule 8: NVMe Critical Warning Byte
            if hw.criticalWarning != 0 {
                issues.append(HealthIssue(
                    code: "SMART_CRITICAL_WARNING",
                    severity: .critical,
                    title: "NVMe S.M.A.R.T. Critical Warning",
                    detail: String(format: "NVMe controller reported CRITICAL_WARNING = 0x%02X.", hw.criticalWarning)
                ))
                score -= 50
            }

            // Rule 9: Temperature
            if tempC >= cfg.tempCriticalCelsius {
                issues.append(HealthIssue(
                    code: "TEMP_CRITICAL",
                    severity: .critical,
                    title: "Drive Overheating (Critical)",
                    detail: "Temperature is \(tempC)°C (>= \(cfg.tempCriticalCelsius)°C thermal damage threshold)."
                ))
                score -= 35
            } else if tempC >= cfg.tempWarningCelsius {
                issues.append(HealthIssue(
                    code: "TEMP_WARNING",
                    severity: .warning,
                    title: "Elevated Drive Temperature",
                    detail: "Temperature is \(tempC)°C (>= \(cfg.tempWarningCelsius)°C warning threshold)."
                ))
                score -= 15
            }

            if !inWakeGrace && tempC > 0 {
                let (updatedSamples, spikeIssue, spikePenalty) = DiskHealthMonitor.evaluateThermalSpike(
                    samples: recentTemperatureSamples[driveKey] ?? [],
                    currentTempC: tempC,
                    nowTs: nowTs
                )
                recentTemperatureSamples[driveKey] = updatedSamples
                if let spikeIssue = spikeIssue {
                    issues.append(spikeIssue)
                    score -= spikePenalty
                }
            }

            // Rule 10: Available Spare Blocks & Percentage Used
            let spareThresh = Int(hw.availableSpareThreshold)
            let isSpareDepleted = (spareThresh <= 50 && hw.availableSpare <= hw.availableSpareThreshold) || hw.availableSpare < 10
            if isSpareDepleted {
                issues.append(HealthIssue(
                    code: "SPARE_CRITICAL",
                    severity: .critical,
                    title: "Available Spare Blocks Depleted",
                    detail: "Available spare (\(hw.availableSpare)%) is at or below threshold (\(hw.availableSpareThreshold)%)."
                ))
                score -= 40
            } else if hw.availableSpare < 25 {
                issues.append(HealthIssue(
                    code: "SPARE_WARNING",
                    severity: .warning,
                    title: "Available Spare Blocks Low",
                    detail: "Available spare blocks dropped to \(hw.availableSpare)%."
                ))
                score -= 15
            }

            if hw.percentageUsed >= 95 {
                issues.append(HealthIssue(
                    code: "WEAR_CRITICAL",
                    severity: .critical,
                    title: "SSD Lifespan Critical",
                    detail: "Percentage Used is \(hw.percentageUsed)% (only \(max(0, 100 - Int(hw.percentageUsed)))% life remaining)."
                ))
                score -= 30
            } else if hw.percentageUsed >= 80 {
                issues.append(HealthIssue(
                    code: "WEAR_WARNING",
                    severity: .warning,
                    title: "SSD Wear Level High",
                    detail: "NVMe Percentage Used has reached \(hw.percentageUsed)%."
                ))
                score -= 10
            }

            // Rule 11: Media Errors, Error Log Entries & Unsafe Shutdowns
            if hw.mediaErrors > (driveState.baselineMediaErrors ?? 0) {
                issues.append(HealthIssue(
                    code: "MEDIA_ERRORS",
                    severity: .critical,
                    title: "NVMe Media / Data Integrity Errors",
                    detail: "Drive reported \(hw.mediaErrors) media/data integrity errors (baseline: \(driveState.baselineMediaErrors ?? 0))."
                ))
                score -= 45
            }

            if let baseErr = driveState.baselineErrorLogEntries, hw.errorInfoLogEntries > baseErr {
                issues.append(HealthIssue(
                    code: "ERROR_LOG_INCREASED",
                    severity: .warning,
                    title: "NVMe Error Log Entries Increased",
                    detail: "Error log count increased from \(baseErr) to \(hw.errorInfoLogEntries)."
                ))
                score -= 15
            }

            if let baseUnsafe = driveState.baselineUnsafeShutdowns, hw.unsafeShutdowns > baseUnsafe {
                let delta = hw.unsafeShutdowns - baseUnsafe
                issues.append(HealthIssue(
                    code: "NEW_UNSAFE_SHUTDOWN",
                    severity: .warning,
                    title: "Unexpected Disconnect / Unsafe Shutdown",
                    detail: "Unsafe shutdown counter increased by +\(delta) (from \(baseUnsafe) to \(hw.unsafeShutdowns))."
                ))
                score -= 15
            }
        }

        // Rule 12: Driver I/O Errors, Driver Latency & Volume Verification Status
        if hw.statsValid {
            if hw.errorsRead > (driveState.baselineIoReadErrors ?? 0) || hw.errorsWritten > (driveState.baselineIoWriteErrors ?? 0) {
                issues.append(HealthIssue(
                    code: "IO_DRIVER_ERRORS",
                    severity: .critical,
                    title: "Storage Driver I/O Errors",
                    detail: "macOS driver recorded \(hw.errorsRead) Read errors and \(hw.errorsWritten) Write errors."
                ))
                score -= 40
            }
            if hw.retriesRead > (driveState.baselineIoReadRetries ?? 0) || hw.retriesWritten > (driveState.baselineIoWriteRetries ?? 0) {
                issues.append(HealthIssue(
                    code: "IO_DRIVER_RETRIES",
                    severity: .warning,
                    title: "Storage Driver Retries Detected",
                    detail: "macOS driver recorded \(hw.retriesRead) Read retries and \(hw.retriesWritten) Write retries."
                ))
                score -= 10
            }
            let (latIssue, latPenalty) = DiskHealthMonitor.evaluateDriverLatency(
                statsValid: hw.statsValid,
                operationsRead: hw.operationsRead,
                operationsWritten: hw.operationsWritten,
                avgReadLatMs: avgReadLatMs,
                avgWriteLatMs: avgWriteLatMs
            )
            if let issue = latIssue {
                issues.append(issue)
                score -= latPenalty
            }
        }

        // Host macOS Thermal Pressure Check
        let (thermalIssue, thermalPenalty) = DiskHealthMonitor.evaluateHostThermal(thermalState: ProcessInfo.processInfo.thermalState)
        if let issue = thermalIssue {
            issues.append(issue)
            score -= thermalPenalty
        }

        if !driveState.lastVerifyOk {
            if DiskHealthMonitor.isNonCorruptionVerifyFailure(driveState.lastVerifyResult) {
                state.updateDriveState(key: driveKey) {
                    $0.lastVerifyOk = true
                    if !$0.lastVerifyResult.starts(with: "Skipped") {
                        $0.lastVerifyResult = "Skipped: Requires administrator privileges (-69863)"
                    }
                }
                driveState.lastVerifyOk = true
            } else {
                issues.append(HealthIssue(
                    code: "VOLUME_VERIFY_FAILED",
                    severity: .critical,
                    title: "File System Verification Failed",
                    detail: driveState.lastVerifyResult
                ))
                score -= 40
            }
        }

        score = max(0, min(100, score))

        let overallSeverity: HealthSeverity = issues.reduce(.healthy) { current, issue in
            issue.severity.rank > current.rank ? issue.severity : current
        }

        let tbRead = Double(hw.dataUnitsRead) * 512_000.0 / 1_000_000_000_000.0
        let tbWritten = Double(hw.dataUnitsWritten) * 512_000.0 / 1_000_000_000_000.0
        let lifeRemaining = max(0, 100 - Int(hw.percentageUsed))

        let snapshot = DiskHealthSnapshot(
            timestamp: nowTs,
            formattedTime: formattedTime,
            formattedShortTime: formattedShortTime,
            overallSeverity: overallSeverity,
            healthScore: score,
            issues: issues,
            hardwareFound: hw.found,
            vendorName: vendorName,
            productName: productName,
            productRevision: productRevision,
            bsdName: bsdName,
            serialNumber: serialNumber,
            usbSerialNumber: serialNumber,
            interconnectType: interconnect,
            protocolType: protocolType,
            isInternal: hw.isInternal,
            isRemovable: hw.isRemovable,
            linkSpeedBps: hw.linkSpeedBps,
            linkSpeedFormatted: linkSpeedFormatted,
            isMounted: isMounted,
            mountPoint: mountPoint,
            filesystemType: fsType,
            isReadOnly: isReadOnly,
            totalBytes: totalBytes,
            freeBytes: freeBytes,
            purgeableBytes: purgeableBytes,
            usedBytes: usedBytes,
            usedPercent: usedPercent,
            subpathsStatus: subpathsStatus,
            canaryOk: canaryOk,
            canaryLatencyMs: canaryLatencyMs,
            canaryError: canaryError,
            smartValid: hw.smartValid,
            criticalWarning: hw.criticalWarning,
            temperatureCelsius: tempC,
            peakTemperatureCelsius: driveState.peakTemperatureCelsius,
            availableSpare: hw.availableSpare,
            availableSpareThreshold: hw.availableSpareThreshold,
            percentageUsed: hw.percentageUsed,
            lifeRemainingPercent: lifeRemaining,
            totalTerabytesRead: tbRead,
            totalTerabytesWritten: tbWritten,
            powerCycles: hw.powerCycles,
            powerOnHours: hw.powerOnHours,
            unsafeShutdowns: hw.unsafeShutdowns,
            mediaErrors: hw.mediaErrors,
            errorInfoLogEntries: hw.errorInfoLogEntries,
            statsValid: hw.statsValid,
            sessionBytesRead: hw.bytesRead,
            sessionBytesWritten: hw.bytesWritten,
            operationsRead: hw.operationsRead,
            operationsWritten: hw.operationsWritten,
            errorsRead: hw.errorsRead,
            errorsWritten: hw.errorsWritten,
            retriesRead: hw.retriesRead,
            retriesWritten: hw.retriesWritten,
            avgReadLatencyMs: avgReadLatMs,
            avgWriteLatencyMs: avgWriteLatMs,
            readThroughputMBps: readMBps,
            writeThroughputMBps: writeMBps,
            lastVerifyResult: driveState.lastVerifyResult,
            lastVerifyOk: driveState.lastVerifyOk
        )

        // Write snapshot JSON to latest_status.json
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let jsonData = try? encoder.encode(snapshot) {
            let latestPath = ConfigManager.shared.latestJsonPath
            try? jsonData.write(to: URL(fileURLWithPath: latestPath), options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: latestPath)
        }

        if allowNotifications {
            processAlertsAndDigestLocked(snapshot: snapshot, rawMetrics: hw, driveKey: driveKey)
        }

        saveStateLocked()

        if Thread.isMainThread {
            self.currentSnapshot = snapshot
        } else {
            DispatchQueue.main.async {
                self.currentSnapshot = snapshot
            }
        }
        return snapshot
    }

    private func processAlertsAndDigestLocked(snapshot: DiskHealthSnapshot, rawMetrics hw: DiskHardwareMetrics, driveKey: String) {
        let nowTs = snapshot.timestamp
        let cfg = ConfigManager.shared.currentConfig
        let cooldown = cfg.alertCooldownSeconds
        var shouldSendAlert = false

        for issue in snapshot.issues {
            let scopedKey = "\(driveKey):\(issue.code)"
            if let legacyTs = state.lastAlertTimestampByCode.removeValue(forKey: issue.code) {
                if state.lastAlertTimestampByCode[scopedKey] == nil {
                    state.lastAlertTimestampByCode[scopedKey] = legacyTs
                }
            }
            let lastSent = state.lastAlertTimestampByCode[scopedKey] ?? 0
            if (nowTs - lastSent) >= cooldown {
                shouldSendAlert = true
                state.lastAlertTimestampByCode[scopedKey] = nowTs
            }
        }

        let driveSeverityRaw = state.drives[driveKey]?.lastOverallSeverity ?? state.lastOverallSeverity
        let prevSeverity = HealthSeverity(rawValue: driveSeverityRaw) ?? .healthy
        if shouldSendAlert {
            let alertTitle = snapshot.overallSeverity == .critical
                ? "\(snapshot.productName) CRITICAL HEALTH ALERT"
                : "\(snapshot.productName) HEALTH WARNING"

            ConfigManager.shared.log("Alert triggered: \(alertTitle) — \(snapshot.issues.map { $0.title }.joined(separator: ", "))")

            // Send macOS notification
            if cfg.enableNativeNotifications {
                let body = snapshot.issues.map { "• \($0.title)" }.joined(separator: "\n")
                MacOSNotifier.shared.postNotification(
                    title: alertTitle,
                    subtitle: "Score: \(snapshot.healthScore)/100 (\(snapshot.overallSeverity.rawValue))",
                    body: body,
                    identifier: "disk-health-alert-\(driveKey)"
                )
            }

            // Advance persistent baselines so user is not repeatedly alerted for the same historical event
            if snapshot.issues.contains(where: { $0.code == "NEW_UNSAFE_SHUTDOWN" }) && hw.smartValid {
                self.state.updateDriveState(key: driveKey) { $0.baselineUnsafeShutdowns = hw.unsafeShutdowns }
            }
            if snapshot.issues.contains(where: { $0.code == "ERROR_LOG_INCREASED" }) && hw.smartValid {
                self.state.updateDriveState(key: driveKey) { $0.baselineErrorLogEntries = hw.errorInfoLogEntries }
            }
            if snapshot.issues.contains(where: { $0.code == "IO_DRIVER_RETRIES" }) && hw.statsValid {
                self.state.updateDriveState(key: driveKey) {
                    $0.baselineIoReadRetries = hw.retriesRead
                    $0.baselineIoWriteRetries = hw.retriesWritten
                }
            }

            // Send Telegram alert
            let htmlMsg = TelegramNotifier.shared.formatReportHTML(snapshot: snapshot, title: alertTitle)
            TelegramNotifier.shared.sendMessageAsync(htmlText: htmlMsg, disableNotification: false)
            WebhookNotifier.shared.sendWebhookAsync(snapshot: snapshot, title: alertTitle, eventType: "health_alert")
            executeAlertScriptAsync(snapshot: snapshot, title: alertTitle, eventType: "health_alert")
        } else if prevSeverity != .healthy && snapshot.overallSeverity == .healthy {
            // Recovery notification
            let recoveryTitle = "\(snapshot.productName) RECOVERED — HEALTHY"
            ConfigManager.shared.log("Drive recovered to HEALTHY state.")
            let prefix = "\(driveKey):"
            for key in Array(state.lastAlertTimestampByCode.keys) where key.hasPrefix(prefix) || !key.contains(":") {
                state.lastAlertTimestampByCode.removeValue(forKey: key)
            }

            if cfg.enableNativeNotifications {
                MacOSNotifier.shared.postNotification(
                    title: recoveryTitle,
                    subtitle: "Score: \(snapshot.healthScore)/100",
                    body: "All storage and filesystem health checks passed.",
                    identifier: "disk-health-alert-\(driveKey)"
                )
            }

            let msg = TelegramNotifier.shared.formatReportHTML(snapshot: snapshot, title: recoveryTitle)
            TelegramNotifier.shared.sendMessageAsync(htmlText: msg, disableNotification: false)
            WebhookNotifier.shared.sendWebhookAsync(snapshot: snapshot, title: recoveryTitle, eventType: "health_recovered")
            executeAlertScriptAsync(snapshot: snapshot, title: recoveryTitle, eventType: "health_recovered")
        }

        state.lastOverallSeverity = snapshot.overallSeverity.rawValue
        state.updateDriveState(key: driveKey) {
            $0.lastOverallSeverity = snapshot.overallSeverity.rawValue
        }

        // Daily Digest at 09:00
        if state.dailySummaryEnabled {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "yyyy-MM-dd"
            let todayStr = df.string(from: Date())
            let hour = Calendar.current.component(.hour, from: Date())
            if state.lastDailySummaryDate.isEmpty {
                state.lastDailySummaryDate = todayStr
            } else if state.lastDailySummaryDate != todayStr && hour >= 9 {
                state.lastDailySummaryDate = todayStr
                let msg = TelegramNotifier.shared.formatReportHTML(snapshot: snapshot, title: "\(snapshot.productName) Daily Health Digest")
                TelegramNotifier.shared.sendMessageAsync(htmlText: msg, disableNotification: true)
            }
        }
    }

    func runVolumeVerification(sendTelegram: Bool = true, completion: ((Bool, String) -> Void)? = nil) {
        engineLock.lock()
        if isVerifyingInternal {
            engineLock.unlock()
            completion?(false, "Verification already in progress")
            return
        }
        let snap = self.currentSnapshot ?? self.evaluateHealth(forceCanary: false, allowNotifications: false)
        let snapMount = snap.mountPoint
        let cfgVol = ConfigManager.shared.currentConfig.targetVolumePath ?? ""
        let target = !snapMount.isEmpty ? snapMount : (!cfgVol.isEmpty ? cfgVol : (!snap.bsdName.isEmpty ? "/dev/\(snap.bsdName)" : "/"))
        let capturedDriveKey = !snap.serialNumber.isEmpty
            ? snap.serialNumber
            : (!snap.bsdName.isEmpty ? snap.bsdName : (target.isEmpty ? "default" : target))
        isVerifyingInternal = true
        engineLock.unlock()

        if Thread.isMainThread {
            self.isVerifyingVolume = true
        } else {
            DispatchQueue.main.async { self.isVerifyingVolume = true }
        }

        ConfigManager.shared.log("Starting diskutil verifyVolume on '\(target)' (driveKey: \(capturedDriveKey))...")

        DispatchQueue.global(qos: .utility).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            proc.arguments = ["verifyVolume", target]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            let readHandle = pipe.fileHandleForReading

            var ok = false
            var summary = ""
            do {
                try proc.run()

                // 180-second watchdog timer in case diskutil or child fsck hangs on a wedged USB bridge
                let timeoutLock = NSLock()
                var timedOut = false
                var killWorkItem: DispatchWorkItem?
                let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
                watchdog.schedule(deadline: .now() + 180.0)
                watchdog.setEventHandler {
                    if proc.isRunning {
                        timeoutLock.lock()
                        timedOut = true
                        timeoutLock.unlock()
                        let pid = proc.processIdentifier
                        proc.terminate()
                        // Escalate to SIGKILL after 2s if still alive
                        let escalation = DispatchWorkItem {
                            if proc.isRunning && pid > 0 {
                                kill(pid, SIGKILL)
                            }
                        }
                        timeoutLock.lock()
                        killWorkItem = escalation
                        timeoutLock.unlock()
                        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0, execute: escalation)
                    }
                }
                watchdog.resume()

                let data = (try? readHandle.readToEnd()) ?? Data()
                proc.waitUntilExit()
                watchdog.cancel()
                timeoutLock.lock()
                killWorkItem?.cancel()
                let didTimeout = timedOut
                timeoutLock.unlock()
                try? readHandle.close()

                let output = String(decoding: data, as: UTF8.self)
                let timeStr = shortMonthDateFormatter.string(from: Date())
                let classified = DiskHealthMonitor.classifyVolumeVerificationOutput(
                    terminationStatus: proc.terminationStatus,
                    output: output,
                    didTimeout: didTimeout,
                    timeStr: timeStr
                )
                ok = classified.isHealthy
                summary = classified.summary
            } catch {
                ok = true
                summary = "Skipped: Could not launch diskutil (\(error.localizedDescription))"
            }

            self.engineLock.lock()
            self.state.updateDriveState(key: capturedDriveKey) {
                $0.lastVerifyTimestamp = Date().timeIntervalSince1970
                $0.lastVerifyOk = ok
                $0.lastVerifyResult = summary
            }
            self.saveStateLocked()
            self.isVerifyingInternal = false
            self.engineLock.unlock()

            ConfigManager.shared.log("Volume verification finished: ok=\(ok), result=\(summary)")

            let updatedSnap = self.evaluateHealth(forceCanary: true, allowNotifications: !ok)
            if sendTelegram {
                let title: String
                if summary.starts(with: "Verified OK") {
                    title = "\(updatedSnap.productName) File System Verification Passed"
                } else if summary.starts(with: "Skipped") {
                    title = "\(updatedSnap.productName) File System Verification Skipped"
                } else {
                    title = "\(updatedSnap.productName) File System Verification FAILED"
                }
                let html = TelegramNotifier.shared.formatReportHTML(snapshot: updatedSnap, title: title)
                TelegramNotifier.shared.sendMessageAsync(htmlText: html, disableNotification: ok)
            }

            DispatchQueue.main.async {
                self.isVerifyingVolume = false
            }
            completion?(ok, summary)
        }
    }

    // MARK: - Rule 8: Storage Driver Latency Evaluation
    static func evaluateDriverLatency(statsValid: Bool, operationsRead: UInt64, operationsWritten: UInt64, avgReadLatMs: Double, avgWriteLatMs: Double) -> (issue: HealthIssue?, scorePenalty: Int) {
        guard statsValid else { return (nil, 0) }
        let maxAvgLatMs = max(
            operationsRead >= 100 ? avgReadLatMs : 0.0,
            operationsWritten >= 100 ? avgWriteLatMs : 0.0
        )
        if maxAvgLatMs > 200.0 {
            return (HealthIssue(
                code: "IO_LATENCY_CRITICAL",
                severity: .critical,
                title: "Critical Storage I/O Latency",
                detail: String(format: "Average driver latency is %.1f ms R / %.1f ms W (> 200 ms).", avgReadLatMs, avgWriteLatMs)
            ), 25)
        } else if maxAvgLatMs > 50.0 {
            return (HealthIssue(
                code: "IO_LATENCY_WARNING",
                severity: .warning,
                title: "Elevated Storage I/O Latency",
                detail: String(format: "Average driver latency is %.1f ms R / %.1f ms W (> 50 ms).", avgReadLatMs, avgWriteLatMs)
            ), 10)
        }
        return (nil, 0)
    }

    // MARK: - Rule 6: Host Thermal State Evaluation
    static func evaluateHostThermal(thermalState: ProcessInfo.ThermalState) -> (issue: HealthIssue?, scorePenalty: Int) {
        if thermalState == .critical {
            return (HealthIssue(
                code: "HOST_THERMAL_CRITICAL",
                severity: .warning,
                title: "Host Mac Thermal Throttling",
                detail: "macOS reported critical system thermal pressure; storage controller may throttle."
            ), 10)
        }
        return (nil, 0)
    }

    // MARK: - Custom Alert Script Execution Hook
    private let notificationGroup = DispatchGroup()

    func waitForPendingNotifications(timeout: TimeInterval = 3.0) {
        _ = notificationGroup.wait(timeout: .now() + timeout)
    }

    func testAlertScript() -> (ok: Bool, summary: String) {
        let rawScriptPath = ConfigManager.shared.resolvedAlertScriptPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawScriptPath.isEmpty else {
            return (false, "No alert script configured. Set alertScriptPath in Settings or via ALERT_SCRIPT_PATH environment variable.")
        }
        let expandedPath = (rawScriptPath as NSString).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: expandedPath) else {
            return (false, "Alert script is not executable: \(expandedPath)")
        }

        let snap = self.currentSnapshot ?? self.evaluateHealth(forceCanary: false, allowNotifications: false)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: expandedPath)
        let pipeOut = Pipe()
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = pipeOut
        proc.standardError = pipeOut
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "TELEGRAM_BOT_TOKEN")
        env.removeValue(forKey: "WEBHOOK_URL")
        env["DISK_HEALTH_EVENT"] = "test_alert"
        env["DISK_HEALTH_TITLE"] = "\(snap.productName) Alert Script Test"
        env["DISK_HEALTH_SEVERITY"] = snap.overallSeverity.rawValue
        env["DISK_HEALTH_SCORE"] = "\(snap.healthScore)"
        env["DISK_HEALTH_DEVICE"] = "\(snap.vendorName) \(snap.productName)".trimmingCharacters(in: .whitespaces)
        env["DISK_HEALTH_BSD_NAME"] = snap.bsdName
        env["DISK_HEALTH_MOUNT_POINT"] = snap.mountPoint
        env["DISK_HEALTH_TEMP_C"] = "\(snap.temperatureCelsius)"
        env["DISK_HEALTH_ISSUES"] = snap.issues.map { "[\($0.code)] \($0.title)" }.joined(separator: "; ")
        proc.environment = env

        do {
            try proc.run()
            proc.waitUntilExit()
            let outputData = (try? pipeOut.fileHandleForReading.readToEnd()) ?? Data()
            let outputStr = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let outSuffix = outputStr.isEmpty ? "" : "\n\(outputStr)"
            if proc.terminationStatus == 0 {
                return (true, "✅ Alert script executed successfully (exit code 0).\(outSuffix)")
            } else {
                return (false, "❌ Alert script failed with exit code \(proc.terminationStatus).\(outSuffix)")
            }
        } catch {
            return (false, "❌ Failed to execute alert script: \(error.localizedDescription)")
        }
    }

    private func executeAlertScriptAsync(snapshot: DiskHealthSnapshot, title: String, eventType: String) {
        let rawScriptPath = ConfigManager.shared.resolvedAlertScriptPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawScriptPath.isEmpty else { return }
        let expandedPath = (rawScriptPath as NSString).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: expandedPath) else {
            ConfigManager.shared.log("Alert script skipped (not executable): \(expandedPath)")
            return
        }

        notificationGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { self.notificationGroup.leave() }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: expandedPath)
            proc.standardInput = FileHandle.nullDevice
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "TELEGRAM_BOT_TOKEN")
            env.removeValue(forKey: "WEBHOOK_URL")
            env["DISK_HEALTH_EVENT"] = eventType
            env["DISK_HEALTH_TITLE"] = title
            env["DISK_HEALTH_SEVERITY"] = snapshot.overallSeverity.rawValue
            env["DISK_HEALTH_SCORE"] = "\(snapshot.healthScore)"
            env["DISK_HEALTH_DEVICE"] = "\(snapshot.vendorName) \(snapshot.productName)".trimmingCharacters(in: .whitespaces)
            env["DISK_HEALTH_BSD_NAME"] = snapshot.bsdName
            env["DISK_HEALTH_MOUNT_POINT"] = snapshot.mountPoint
            env["DISK_HEALTH_TEMP_C"] = "\(snapshot.temperatureCelsius)"
            env["DISK_HEALTH_ISSUES"] = snapshot.issues.map { "[\($0.code)] \($0.title)" }.joined(separator: "; ")
            proc.environment = env

            do {
                try proc.run()
                let pid = proc.processIdentifier
                let timeoutLock = NSLock()
                var killWorkItem: DispatchWorkItem?
                let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
                watchdog.schedule(deadline: .now() + 15.0)
                watchdog.setEventHandler {
                    if proc.isRunning {
                        proc.terminate()
                        let escalation = DispatchWorkItem {
                            if proc.isRunning && pid > 0 {
                                kill(pid, SIGKILL)
                            }
                        }
                        timeoutLock.lock()
                        killWorkItem = escalation
                        timeoutLock.unlock()
                        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0, execute: escalation)
                    }
                }
                watchdog.resume()
                proc.waitUntilExit()
                watchdog.cancel()
                timeoutLock.lock()
                killWorkItem?.cancel()
                timeoutLock.unlock()
                ConfigManager.shared.log("Alert script executed (\(expandedPath)): exit=\(proc.terminationStatus)")
            } catch {
                ConfigManager.shared.log("Alert script failed to launch (\(expandedPath)): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Non-Destructive Surface Read Scanner (Quick / Standard / Full)
    enum SurfaceScanMode: String, CaseIterable, Identifiable {
        case quick = "quick"
        case standard = "standard"
        case full = "full"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .quick: return "Quick Probe (64 MB)"
            case .standard: return "Standard Scan (2 GB)"
            case .full: return "Full Volume Scan"
            }
        }

        var shortLabel: String {
            switch self {
            case .quick: return "Quick (64 MB)"
            case .standard: return "Standard (2 GB)"
            case .full: return "Full Volume"
            }
        }

        var modeDescription: String {
            switch self {
            case .quick:
                return "Samples up to 120 files (256 KB/file, 64 MB cap) using F_NOCACHE direct reads (~0.2s)."
            case .standard:
                return "Scans up to 2,000 files (2 MB/file, 2 GB cap) across the volume using uncached reads (~3–5s)."
            case .full:
                return "Streams all readable allocated files across the volume in 1 MB uncached blocks with live throughput & ETA."
            }
        }

        var maxBytes: UInt64 {
            switch self {
            case .quick: return 64 * 1024 * 1024
            case .standard: return 2 * 1024 * 1024 * 1024
            case .full: return UInt64.max
            }
        }

        var maxFiles: Int {
            switch self {
            case .quick: return 120
            case .standard: return 2_000
            case .full: return Int.max
            }
        }

        var maxBytesPerFile: Int {
            switch self {
            case .quick: return 256 * 1024
            case .standard: return 2 * 1024 * 1024
            case .full: return Int.max
            }
        }

        var chunkSize: Int {
            switch self {
            case .quick: return 256 * 1024
            case .standard, .full: return 1024 * 1024
            }
        }
    }

    struct SurfaceScanProgress {
        let mode: SurfaceScanMode
        let filesScanned: Int
        let bytesScanned: UInt64
        let targetBytes: UInt64
        let readErrors: Int
        let throughputMBps: Double
        let fractionCompleted: Double
        let estimatedRemainingSec: Double?
        let currentFile: String

        var formattedBytesScanned: String {
            ByteCountFormatter.string(fromByteCount: Int64(bytesScanned), countStyle: .file)
        }

        var formattedTargetBytes: String {
            ByteCountFormatter.string(fromByteCount: Int64(targetBytes), countStyle: .file)
        }

        var formattedThroughput: String {
            String(format: "%.1f MB/s", throughputMBps)
        }

        var formattedPercent: String {
            String(format: "%.1f%%", min(100.0, max(0.0, fractionCompleted * 100.0)))
        }

        var formattedETA: String? {
            guard let sec = estimatedRemainingSec, sec > 0 else { return nil }
            if sec < 60 {
                return String(format: "%.0fs", sec)
            } else if sec < 3600 {
                let m = Int(sec) / 60
                let s = Int(sec) % 60
                return "\(m)m \(s)s"
            } else {
                let h = Int(sec) / 3600
                let m = (Int(sec) % 3600) / 60
                return "\(h)h \(m)m"
            }
        }
    }

    final class SurfaceScanCancellationToken {
        private let lock = NSLock()
        private var _isCancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _isCancelled
        }

        func cancel() {
            lock.lock()
            _isCancelled = true
            lock.unlock()
        }
    }

    func runSurfaceReadScan(
        mode: SurfaceScanMode = .quick,
        maxBytesToScan: UInt64? = nil,
        cancellationToken: SurfaceScanCancellationToken? = nil,
        progressHandler: ((SurfaceScanProgress) -> Void)? = nil
    ) -> (ok: Bool, filesScanned: Int, bytesScanned: UInt64, readErrors: Int, elapsedMs: Double, summary: String) {
        let snap = self.currentSnapshot ?? self.evaluateHealth(forceCanary: false, allowNotifications: false)
        guard snap.isMounted, !snap.mountPoint.isEmpty else {
            return (false, 0, 0, 1, 0.0, "Surface scan aborted: Target volume is not mounted.")
        }

        let scanRoot: String
        if snap.mountPoint == "/" {
            scanRoot = (mode == .quick) ? "/System/Library/CoreServices" : "/"
        } else {
            scanRoot = snap.mountPoint
        }

        let effectiveMaxBytes = maxBytesToScan ?? mode.maxBytes
        let effectiveMaxFiles = mode.maxFiles
        let maxPerFile = mode.maxBytesPerFile
        let bufSize = mode.chunkSize

        let allocatedVolumeBytes: UInt64 = {
            if snap.totalBytes > snap.freeBytes {
                return max(1, snap.totalBytes - snap.freeBytes)
            }
            return max(1, snap.totalBytes)
        }()

        let estimatedTargetBytes: UInt64 = {
            switch mode {
            case .quick, .standard:
                return min(effectiveMaxBytes, allocatedVolumeBytes)
            case .full:
                return allocatedVolumeBytes
            }
        }()

        let start = DispatchTime.now()
        var lastProgressReportNs = start.uptimeNanoseconds
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: scanRoot),
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return (false, 0, 0, 1, 0.0, "Surface scan failed: Unable to enumerate \(scanRoot).")
        }

        var filesScanned = 0
        var bytesScanned: UInt64 = 0
        var readErrors = 0
        var wasCancelled = false

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 4096)
        defer { buffer.deallocate() }

        let emitProgress: (String, Bool) -> Void = { currentPath, force in
            guard let handler = progressHandler else { return }
            let nowNs = DispatchTime.now().uptimeNanoseconds
            if !force && (nowNs - lastProgressReportNs) < 100_000_000 { return }
            lastProgressReportNs = nowNs

            let elapsedSec = max(0.001, Double(nowNs - start.uptimeNanoseconds) / 1_000_000_000.0)
            let mbps = (Double(bytesScanned) / (1024.0 * 1024.0)) / elapsedSec

            let fraction: Double
            if mode == .full {
                fraction = min(0.99, Double(bytesScanned) / Double(max(1, estimatedTargetBytes)))
            } else {
                let byteFrac = Double(bytesScanned) / Double(max(1, effectiveMaxBytes))
                let fileFrac = Double(filesScanned) / Double(max(1, effectiveMaxFiles))
                fraction = min(0.99, max(byteFrac, fileFrac))
            }

            let eta: Double?
            if fraction > 0.01 && mbps > 0.1 {
                let remainingBytes = estimatedTargetBytes > bytesScanned ? (estimatedTargetBytes - bytesScanned) : 0
                eta = Double(remainingBytes) / (mbps * 1024.0 * 1024.0)
            } else {
                eta = nil
            }

            handler(SurfaceScanProgress(
                mode: mode,
                filesScanned: filesScanned,
                bytesScanned: bytesScanned,
                targetBytes: estimatedTargetBytes,
                readErrors: readErrors,
                throughputMBps: mbps,
                fractionCompleted: fraction,
                estimatedRemainingSec: eta,
                currentFile: (currentPath as NSString).lastPathComponent
            ))
        }

        outerLoop: for case let fileURL as URL in enumerator {
            if cancellationToken?.isCancelled == true {
                wasCancelled = true
                break
            }
            if bytesScanned >= effectiveMaxBytes || filesScanned >= effectiveMaxFiles {
                break
            }

            let path = fileURL.path
            if snap.mountPoint == "/" && mode != .quick {
                if path.hasPrefix("/dev/") || path.hasPrefix("/Volumes/") || path.hasPrefix("/System/Volumes/Data/Volumes/") {
                    enumerator.skipDescendants()
                    continue
                }
            }

            guard let vals = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  vals.isRegularFile == true,
                  let fSize = vals.fileSize, fSize > 0 else { continue }

            let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0 { continue }
            _ = fcntl(fd, F_NOCACHE, 1) // Bypass unified buffer cache to force physical media read

            let fileTargetBytes = min(fSize, maxPerFile)
            var fileBytesRead = 0
            var countedFile = false

            while fileBytesRead < fileTargetBytes && bytesScanned < effectiveMaxBytes {
                if cancellationToken?.isCancelled == true {
                    wasCancelled = true
                    close(fd)
                    break outerLoop
                }

                let remainingForFile = fileTargetBytes - fileBytesRead
                let remainingGlobal = Int(min(UInt64(Int.max), effectiveMaxBytes - bytesScanned))
                let toRead = min(bufSize, min(remainingForFile, remainingGlobal))
                if toRead <= 0 { break }

                let n = read(fd, buffer, toRead)
                if n < 0 {
                    let err = errno
                    if err == EIO || err == ENXIO || err == ETIMEDOUT {
                        readErrors += 1
                    }
                    break
                } else if n == 0 {
                    break
                } else {
                    fileBytesRead += n
                    bytesScanned += UInt64(n)
                    if !countedFile {
                        filesScanned += 1
                        countedFile = true
                    }
                    emitProgress(path, false)
                }
            }
            close(fd)
        }

        emitProgress("", true)

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
        let elapsedSec = max(0.001, elapsedMs / 1000.0)
        let avgMBps = (Double(bytesScanned) / (1024.0 * 1024.0)) / elapsedSec

        if wasCancelled {
            let summary = String(
                format: "CANCELLED [%@] after %d files (%@ read at %.1f MB/s in %.2f s, %d I/O errors)",
                mode.shortLabel, filesScanned, formatBytes(bytesScanned), avgMBps, elapsedSec, readErrors
            )
            ConfigManager.shared.log("Surface read scan on '\(scanRoot)': \(summary)")
            return (readErrors == 0, filesScanned, bytesScanned, readErrors, elapsedMs, summary)
        }

        if filesScanned == 0 {
            let summary = "WARNING: Surface scan (\(mode.shortLabel)) completed with 0 readable files sampled on '\(scanRoot)' (insufficient regular files or read permissions)."
            ConfigManager.shared.log("Surface read scan on '\(scanRoot)': \(summary)")
            return (false, 0, 0, readErrors, elapsedMs, summary)
        }

        let ok = (readErrors == 0)
        let timeStr = elapsedMs >= 1000.0 ? String(format: "%.2f s", elapsedSec) : String(format: "%.1f ms", elapsedMs)
        let summary = ok
            ? String(format: "PASSED [%@] (%d files, %@ read directly from media at %.1f MB/s in %@, 0 I/O errors)", mode.shortLabel, filesScanned, formatBytes(bytesScanned), avgMBps, timeStr)
            : String(format: "FAILED [%@] (%d physical read errors across %d files, %@ read)", mode.shortLabel, readErrors, filesScanned, formatBytes(bytesScanned))
        ConfigManager.shared.log("Surface read scan on '\(scanRoot)': \(summary)")
        return (ok, filesScanned, bytesScanned, readErrors, elapsedMs, summary)
    }
}
