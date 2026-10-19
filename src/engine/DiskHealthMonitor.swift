import Foundation
import Darwin
import Combine

// MARK: - Core Health Monitor Engine

final class DiskHealthMonitor: ObservableObject {
    static let shared = DiskHealthMonitor()

    @Published private(set) var currentSnapshot: DiskHealthSnapshot?
    @Published private(set) var isVerifyingVolume: Bool = false

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

    private init() {
        self.state = DiskHealthMonitor.loadState()
    }

    private static func loadState() -> DiskPersistentState {
        let path = ConfigManager.shared.stateFilePath
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let decoded = try? JSONDecoder().decode(DiskPersistentState.self, from: data) {
            return decoded
        }
        return DiskPersistentState()
    }

    private func saveStateLocked() {
        let path = ConfigManager.shared.stateFilePath
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(state) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
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

    func setMonitoredTarget(volumePath: String?, deviceQuery: String?) {
        engineLock.lock()
        ConfigManager.shared.updateTarget(volumePath: volumePath, deviceQuery: deviceQuery)
        state.monitoredTarget = volumePath ?? deviceQuery ?? "auto"
        state.lastAlertTimestampByCode.removeAll()
        previousDriveKey = ""
        previousBytesRead = 0
        previousBytesWritten = 0
        previousSampleTime = 0
        lastCanaryRunTime = 0
        saveStateLocked()
        engineLock.unlock()
    }

    func resetBaselines() {
        engineLock.lock()
        defer { engineLock.unlock() }
        self.state = DiskPersistentState()
        saveStateLocked()
        ConfigManager.shared.log("Persistent baselines and health state reset.")
    }

    private func runCanaryCheck(targetMount: String, force: Bool) -> (Bool, Double, String) {
        let now = Date().timeIntervalSince1970
        if !force && (now - lastCanaryRunTime) < 300 && lastCanaryRunTime > 0 {
            return (cachedCanaryOk, cachedCanaryLatencyMs, cachedCanaryError)
        }

        var result = performSingleCanaryPass(targetMount: targetMount)
        if result.0 && result.1 > 300.0 {
            let secondPass = performSingleCanaryPass(targetMount: targetMount)
            if secondPass.0 {
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
        let canaryPath = "\(targetMount)/.disk_health_canary"
        let token = "DISK_HEALTH_CANARY_\(UUID().uuidString)\n"
        guard let data = token.data(using: .utf8) else {
            return (false, 0, "Encoding error")
        }

        let start = DispatchTime.now()
        let fd = open(canaryPath, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
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
        let cfg = ConfigManager.shared.config

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
        var usedBytes: UInt64 = 0
        var usedPercent: Double = 0.0

        let mountToInspect = !targetMount.isEmpty ? targetMount : (!targetQuery.isEmpty && targetQuery.starts(with: "/") ? targetQuery : "")
        if !mountToInspect.isEmpty {
            var sfs = statfs()
            if statfs(mountToInspect, &sfs) == 0 {
                let resolvedMountPoint = (cStringToSwift(sfs.f_mntonname) as NSString).standardizingPath
                let resolvedInspect = (mountToInspect as NSString).standardizingPath
                fsType = cStringToSwift(sfs.f_fstypename)

                // If inspecting "/", resolvedMountPoint must be "/".
                // If inspecting "/Volumes/Foo", resolvedMountPoint must equal "/Volumes/Foo"
                // (not "/" when "/Volumes/Foo" is an unmounted stub directory).
                let isValidMatch: Bool
                if resolvedInspect == "/" {
                    isValidMatch = (resolvedMountPoint == "/")
                } else {
                    isValidMatch = (resolvedMountPoint == resolvedInspect) ||
                                   (resolvedMountPoint != "/" && resolvedInspect.hasPrefix(resolvedMountPoint + "/"))
                }

                if isValidMatch {
                    mountPoint = resolvedMountPoint
                    isMounted = true
                    isReadOnly = (sfs.f_flags & UInt32(MNT_RDONLY)) != 0
                    let bsize = UInt64(sfs.f_bsize)
                    totalBytes = UInt64(sfs.f_blocks) * bsize
                    freeBytes = UInt64(sfs.f_bavail) * bsize
                    usedBytes = totalBytes > freeBytes ? (totalBytes - freeBytes) : 0
                    usedPercent = totalBytes > 0 ? (Double(usedBytes) / Double(totalBytes) * 100.0) : 0.0
                }
            }
        }

        // 4. Required Subpaths Check (if user configured any)
        var subpathsStatus: [String: Bool] = [:]
        for subpath in cfg.requiredSubpaths {
            let fullSubpath = "\(mountPoint)/\(subpath)"
            var isDir: ObjCBool = false
            let exists = isMounted && FileManager.default.fileExists(atPath: fullSubpath, isDirectory: &isDir)
            subpathsStatus[subpath] = exists
        }

        let driveKey = !serialNumber.isEmpty ? serialNumber : (!bsdName.isEmpty ? bsdName : (targetMount.isEmpty ? "default" : targetMount))
        if driveKey != previousDriveKey {
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
            if !isReadOnly || mountPoint == "/" {
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
            if driveState.baselineMediaErrors == nil { driveState.baselineMediaErrors = hw.mediaErrors }
            if driveState.baselineErrorLogEntries == nil { driveState.baselineErrorLogEntries = hw.errorInfoLogEntries }
        }
        if hw.statsValid {
            if driveState.baselineIoReadErrors == nil { driveState.baselineIoReadErrors = hw.errorsRead }
            if driveState.baselineIoWriteErrors == nil { driveState.baselineIoWriteErrors = hw.errorsWritten }
            if driveState.baselineIoReadRetries == nil { driveState.baselineIoReadRetries = hw.retriesRead }
            if driveState.baselineIoWriteRetries == nil { driveState.baselineIoWriteRetries = hw.retriesWritten }
        }
        state.drives[driveKey] = driveState

        // 8. Health Evaluation Rules Engine
        var issues: [HealthIssue] = []
        var score = 100

        // Rule 1: Hardware Presence
        if !hw.found {
            issues.append(HealthIssue(
                code: "HW_DISCONNECTED",
                severity: .critical,
                title: "Storage Hardware Disconnected",
                detail: "Target device was not detected on macOS IOKit storage buses."
            ))
            score -= 60
        }

        // Rule 2: Volume Mount Status
        if !mountToInspect.isEmpty && !isMounted {
            issues.append(HealthIssue(
                code: "VOLUME_UNMOUNTED",
                severity: .critical,
                title: "Volume Unmounted",
                detail: "Volume \(mountToInspect) is not mounted."
            ))
            score -= 50
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
                if !canaryOk {
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
            if hw.mediaErrors > (driveState.baselineMediaErrors ?? 0) || hw.mediaErrors > 0 {
                issues.append(HealthIssue(
                    code: "MEDIA_ERRORS",
                    severity: .critical,
                    title: "NVMe Media / Data Integrity Errors",
                    detail: "Drive reported \(hw.mediaErrors) media/data integrity errors."
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

        // Rule 12: Driver I/O Errors & Volume Verification Status
        if hw.statsValid {
            if hw.errorsRead > (driveState.baselineIoReadErrors ?? 0) || hw.errorsWritten > (driveState.baselineIoWriteErrors ?? 0) || hw.errorsRead > 0 || hw.errorsWritten > 0 {
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
        }

        if !driveState.lastVerifyOk {
            issues.append(HealthIssue(
                code: "VOLUME_VERIFY_FAILED",
                severity: .critical,
                title: "File System Verification Failed",
                detail: driveState.lastVerifyResult
            ))
            score -= 40
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
            try? jsonData.write(to: URL(fileURLWithPath: ConfigManager.shared.latestJsonPath))
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
        let cooldown = ConfigManager.shared.config.alertCooldownSeconds
        var shouldSendAlert = false

        for issue in snapshot.issues {
            let lastSent = state.lastAlertTimestampByCode[issue.code] ?? 0
            if (nowTs - lastSent) >= cooldown {
                shouldSendAlert = true
                state.lastAlertTimestampByCode[issue.code] = nowTs
            }
        }

        let prevSeverity = HealthSeverity(rawValue: state.lastOverallSeverity) ?? .healthy
        if shouldSendAlert {
            let alertTitle = snapshot.overallSeverity == .critical
                ? "\(snapshot.productName) CRITICAL HEALTH ALERT"
                : "\(snapshot.productName) HEALTH WARNING"

            ConfigManager.shared.log("Alert triggered: \(alertTitle) — \(snapshot.issues.map { $0.title }.joined(separator: ", "))")

            // Send macOS notification
            if ConfigManager.shared.config.enableNativeNotifications {
                let body = snapshot.issues.map { "• \($0.title)" }.joined(separator: "\n")
                MacOSNotifier.shared.postNotification(
                    title: alertTitle,
                    subtitle: "Score: \(snapshot.healthScore)/100 (\(snapshot.overallSeverity.rawValue))",
                    body: body
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
        } else if prevSeverity != .healthy && snapshot.overallSeverity == .healthy {
            // Recovery notification
            let recoveryTitle = "\(snapshot.productName) RECOVERED — HEALTHY"
            ConfigManager.shared.log("Drive recovered to HEALTHY state.")
            state.lastAlertTimestampByCode.removeAll()

            if ConfigManager.shared.config.enableNativeNotifications {
                MacOSNotifier.shared.postNotification(
                    title: recoveryTitle,
                    subtitle: "Score: \(snapshot.healthScore)/100",
                    body: "All storage and filesystem health checks passed."
                )
            }

            let msg = TelegramNotifier.shared.formatReportHTML(snapshot: snapshot, title: recoveryTitle)
            TelegramNotifier.shared.sendMessageAsync(htmlText: msg, disableNotification: false)
        }

        state.lastOverallSeverity = snapshot.overallSeverity.rawValue

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
        if isVerifyingVolume {
            engineLock.unlock()
            completion?(false, "Verification already in progress")
            return
        }
        engineLock.unlock()

        DispatchQueue.main.async { self.isVerifyingVolume = true }

        let target = self.currentSnapshot?.mountPoint.isEmpty == false
            ? (self.currentSnapshot?.mountPoint ?? "/")
            : (ConfigManager.shared.config.targetVolumePath ?? "/")

        ConfigManager.shared.log("Starting diskutil verifyVolume on '\(target)'...")

        DispatchQueue.global(qos: .utility).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            proc.arguments = ["verifyVolume", target]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe

            var ok = false
            var summary = ""
            do {
                try proc.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                let output = String(decoding: data, as: UTF8.self)
                ok = (proc.terminationStatus == 0) && (output.contains("appears to be OK") || output.contains("Finished file system verification") || output.contains("File system check exit code is 0"))
                let timeStr = shortMonthDateFormatter.string(from: Date())
                if ok {
                    summary = "Verified OK (\(timeStr))"
                } else {
                    let lastLines = output.components(separatedBy: .newlines).filter { !$0.isEmpty }.suffix(2).joined(separator: " | ")
                    summary = "Failed (\(timeStr)): \(lastLines)"
                }
            } catch {
                summary = "Error running diskutil: \(error.localizedDescription)"
            }

            self.engineLock.lock()
            let driveKey = self.currentSnapshot?.serialNumber.isEmpty == false
                ? self.currentSnapshot!.serialNumber
                : (self.currentSnapshot?.bsdName.isEmpty == false ? self.currentSnapshot!.bsdName : "default")
            self.state.updateDriveState(key: driveKey) {
                $0.lastVerifyTimestamp = Date().timeIntervalSince1970
                $0.lastVerifyOk = ok
                $0.lastVerifyResult = summary
            }
            self.saveStateLocked()
            self.engineLock.unlock()

            ConfigManager.shared.log("Volume verification finished: ok=\(ok), result=\(summary)")

            let snap = self.evaluateHealth(forceCanary: true, allowNotifications: true)
            if sendTelegram {
                let title = ok ? "\(snap.productName) File System Verification Passed" : "\(snap.productName) File System Verification FAILED"
                let html = TelegramNotifier.shared.formatReportHTML(snapshot: snap, title: title)
                TelegramNotifier.shared.sendMessageAsync(htmlText: html, disableNotification: ok)
            }

            DispatchQueue.main.async {
                self.isVerifyingVolume = false
            }
            completion?(ok, summary)
        }
    }
}
