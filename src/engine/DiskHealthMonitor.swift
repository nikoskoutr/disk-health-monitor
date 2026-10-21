import Foundation
import Darwin
import Combine
import AppKit

// MARK: - Core Health Monitor Engine

final class DiskHealthMonitor: ObservableObject, @unchecked Sendable {
    static let shared = DiskHealthMonitor()

    typealias SurfaceScanMode = SurfaceScannerService.SurfaceScanMode
    typealias SurfaceScanProgress = SurfaceScannerService.SurfaceScanProgress
    typealias SurfaceScanCancellationToken = SurfaceScannerService.SurfaceScanCancellationToken

    @Published private var publishedSnapshot: DiskHealthSnapshot?
    private var latestSnapshotInternal: DiskHealthSnapshot?

    var currentSnapshot: DiskHealthSnapshot? {
        engineLock.lock()
        defer { engineLock.unlock() }
        return latestSnapshotInternal
    }

    @Published private(set) var isVerifyingVolume: Bool = false
    private var isVerifyingInternal: Bool = false

    private let engineLock = NSRecursiveLock()
    private var state: DiskPersistentState
    private var previousDriveKey: String = ""
    private var previousBytesRead: UInt64 = 0
    private var previousBytesWritten: UInt64 = 0
    private var previousSampleTime: TimeInterval = 0
    private var lastWakeTime: TimeInterval = 0
    private(set) var isSystemSleeping: Bool = false
    private var recentTemperatureSamples: [String: [(timestamp: TimeInterval, tempC: Int)]] = [:]
    private var defaultTelemetryProvider: any DiskTelemetryProvider = IOKitTelemetryProvider.shared

    private init() {
        self.state = DiskHealthMonitor.loadState()
    }

    // MARK: - Static Forwarding Helpers (Backwards Compatibility)

    static func evaluateThermalSpike(samples: [(timestamp: TimeInterval, tempC: Int)], currentTempC: Int, nowTs: TimeInterval) -> (updatedSamples: [(timestamp: TimeInterval, tempC: Int)], issue: HealthIssue?, scorePenalty: Int) {
        ThermalAndSpikeRule.evaluateThermalSpike(samples: samples, currentTempC: currentTempC, nowTs: nowTs)
    }

    static func isNonCorruptionVerifyFailure(_ result: String) -> Bool {
        VolumeVerifierService.isNonCorruptionVerifyFailure(result)
    }

    static func classifyVolumeVerificationOutput(terminationStatus: Int32, output: String, didTimeout: Bool, timeStr: String) -> (isHealthy: Bool, isSkipped: Bool, summary: String) {
        VolumeVerifierService.classifyVolumeVerificationOutput(terminationStatus: terminationStatus, output: output, didTimeout: didTimeout, timeStr: timeStr)
    }

    static func evaluateDriverLatency(statsValid: Bool, operationsRead: UInt64, operationsWritten: UInt64, avgReadLatMs: Double, avgWriteLatMs: Double) -> (issue: HealthIssue?, scorePenalty: Int) {
        DriverStatsAndLatencyRule.evaluateDriverLatency(statsValid: statsValid, operationsRead: operationsRead, operationsWritten: operationsWritten, avgReadLatMs: avgReadLatMs, avgWriteLatMs: avgWriteLatMs)
    }

    static func evaluateHostThermal(thermalState: ProcessInfo.ThermalState) -> (issue: HealthIssue?, scorePenalty: Int) {
        HostThermalAndVerifyRule.evaluateHostThermal(thermalState: thermalState)
    }

    // MARK: - State Persistence

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
                    _ = AtomicFileWriter.writeRestricted(data: outData, toPath: path, permissions: 0o600)
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
            _ = AtomicFileWriter.writeRestricted(data: data, toPath: path, permissions: 0o600)
        }
    }

    // MARK: - System Lifecycle & Sleep/Wake Management

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
        CanaryProbeService.shared.resetCache()
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
        self.latestSnapshotInternal = nil
        engineLock.unlock()
        if Thread.isMainThread {
            self.publishedSnapshot = nil
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.publishedSnapshot = nil
            }
        }
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
            CanaryProbeService.shared.resetCache()
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

    // MARK: - Health Evaluation Pipeline

    @discardableResult
    func evaluateHealth(
        forceCanary: Bool = false,
        allowNotifications: Bool = true,
        telemetryProvider: (any DiskTelemetryProvider)? = nil
    ) -> DiskHealthSnapshot {
        engineLock.lock()
        defer { engineLock.unlock() }

        let provider = telemetryProvider ?? self.defaultTelemetryProvider
        let now = Date()
        let nowTs = now.timeIntervalSince1970
        let formattedTime = isoTimestampFormatter.string(from: now)
        let formattedShortTime = shortTimeFormatter.string(from: now)
        let cfg = ConfigManager.shared.currentConfig

        // 1. Determine Target Mount & Hardware Query
        var targetMount = cfg.targetVolumePath ?? ""
        let targetQuery = cfg.targetDeviceQuery ?? ""

        // 2. Hardware Telemetry Query
        let queryToPass = !targetMount.isEmpty ? targetMount : (!targetQuery.isEmpty ? targetQuery : "auto")
        let hw = provider.readHardwareMetrics(query: queryToPass)

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
            if let resolvedMount = provider.findMountPoint(forBsdName: bsdName) {
                targetMount = resolvedMount
            }
        }

        // 4. Mount & Filesystem Inspection
        let mountToInspect = !targetMount.isEmpty ? targetMount : (!targetQuery.isEmpty && targetQuery.starts(with: "/") ? targetQuery : "")
        let fsMetrics = provider.inspectFilesystem(mountPath: mountToInspect)

        // 5. Required Subpaths Check
        let subpathsStatus = provider.checkSubpaths(
            mountPoint: fsMetrics.mountPoint,
            isMounted: fsMetrics.isMounted,
            requiredSubpaths: cfg.requiredSubpaths
        )

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
            CanaryProbeService.shared.resetCache()
        }

        // 6. Active I/O Canary Probe
        var canaryOk = false
        var canaryLatencyMs = 0.0
        var canaryError = fsMetrics.isMounted ? "Canary disabled" : "Volume not mounted"
        if fsMetrics.isMounted && cfg.enableActiveCanary {
            if isSystemSleeping {
                canaryOk = true
                canaryError = "Suppressed while system is sleeping"
            } else if !fsMetrics.isReadOnly || fsMetrics.mountPoint == "/" {
                let res = provider.runCanaryProbe(targetMount: fsMetrics.mountPoint, force: forceCanary, nowTs: nowTs)
                canaryOk = res.ok
                canaryLatencyMs = res.latencyMs
                canaryError = res.error
            } else {
                canaryOk = false
                canaryError = "Volume is mounted Read-Only"
            }
        }

        // 7. Throughput & Latency Calculations
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

        // 8. Update Peak Temp & Baselines for this specific physical drive
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

        // 9. Evaluate Health Rules Pipeline
        let inWakeGrace = isSystemSleeping || (lastWakeTime > 0 && (nowTs - lastWakeTime < 8.0))
        let evaluationContext = HealthEvaluationContext(
            nowTs: nowTs,
            config: cfg,
            hardware: hw,
            linkSpeedFormatted: linkSpeedFormatted,
            interconnect: interconnect,
            mountToInspect: mountToInspect,
            filesystem: fsMetrics,
            subpathsStatus: subpathsStatus,
            canaryOk: canaryOk,
            canaryLatencyMs: canaryLatencyMs,
            canaryError: canaryError,
            avgReadLatMs: avgReadLatMs,
            avgWriteLatMs: avgWriteLatMs,
            inWakeGrace: inWakeGrace,
            hostThermalState: provider.currentHostThermalState(),
            driveState: driveState,
            recentTemperatureSamples: recentTemperatureSamples[driveKey] ?? []
        )

        var issues: [HealthIssue] = []
        var score = 100

        for rule in StandardHealthRulePipeline.defaultRules {
            let outcome = rule.evaluate(context: evaluationContext)
            for msg in outcome.logMessages {
                ConfigManager.shared.log(msg)
            }
            issues.append(contentsOf: outcome.issues)
            score -= outcome.scorePenalty
            if let updatedTemps = outcome.updatedTemperatureSamples {
                recentTemperatureSamples[driveKey] = updatedTemps
            }
            if outcome.healVerifyFailureToSkipped {
                state.updateDriveState(key: driveKey) {
                    $0.lastVerifyOk = true
                    if !$0.lastVerifyResult.starts(with: "Skipped") {
                        $0.lastVerifyResult = "Skipped: Requires administrator privileges (-69863)"
                    }
                }
                driveState.lastVerifyOk = true
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
            isMounted: fsMetrics.isMounted,
            mountPoint: fsMetrics.mountPoint,
            filesystemType: fsMetrics.filesystemType,
            isReadOnly: fsMetrics.isReadOnly,
            totalBytes: fsMetrics.totalBytes,
            freeBytes: fsMetrics.freeBytes,
            purgeableBytes: fsMetrics.purgeableBytes,
            usedBytes: fsMetrics.usedBytes,
            usedPercent: fsMetrics.usedPercent,
            subpathsStatus: subpathsStatus,
            canaryOk: canaryOk,
            canaryLatencyMs: canaryLatencyMs,
            canaryError: canaryError,
            smartValid: hw.smartValid,
            criticalWarning: hw.criticalWarning,
            temperatureCelsius: tempC,
            temperatureKelvin: Int(hw.temperatureKelvin),
            peakTemperatureCelsius: driveState.peakTemperatureCelsius,
            availableSpare: hw.availableSpare,
            availableSpareThreshold: hw.availableSpareThreshold,
            percentageUsed: hw.percentageUsed,
            lifeRemainingPercent: lifeRemaining,
            dataUnitsRead: hw.dataUnitsRead,
            dataUnitsWritten: hw.dataUnitsWritten,
            totalTerabytesRead: tbRead,
            totalTerabytesWritten: tbWritten,
            hostReadCommands: hw.hostReadCommands,
            hostWriteCommands: hw.hostWriteCommands,
            controllerBusyTime: hw.controllerBusyTime,
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
            _ = AtomicFileWriter.writeRestricted(data: jsonData, toPath: latestPath, permissions: 0o600)
        }

        if allowNotifications {
            processAlertsAndDigestLocked(snapshot: snapshot, rawMetrics: hw, driveKey: driveKey)
        }

        // Check if scheduled background volume verification is due
        if allowNotifications && !isSystemSleeping && !isVerifyingInternal && cfg.scheduledVerifyIntervalHours > 0 && fsMetrics.isMounted {
            let intervalSec = Double(cfg.scheduledVerifyIntervalHours) * 3600.0
            if (nowTs - driveState.lastVerifyTimestamp) >= intervalSec {
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    self?.runVolumeVerification(sendTelegram: true)
                }
            }
        }

        self.latestSnapshotInternal = snapshot
        saveStateLocked()

        if Thread.isMainThread {
            self.publishedSnapshot = snapshot
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.publishedSnapshot = snapshot
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

            if cfg.enableCriticalSoundAlert && snapshot.overallSeverity == .critical && MacOSNotifier.hasValidAppBundle {
                DispatchQueue.main.async {
                    NSSound.beep()
                }
            }

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
            notificationGroup.enter()
            TelegramNotifier.shared.sendMessageAsync(htmlText: htmlMsg, disableNotification: false) { [weak self] _ in
                self?.notificationGroup.leave()
            }
            notificationGroup.enter()
            WebhookNotifier.shared.sendWebhookAsync(snapshot: snapshot, title: alertTitle, eventType: "health_alert") { [weak self] _ in
                self?.notificationGroup.leave()
            }
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
            notificationGroup.enter()
            TelegramNotifier.shared.sendMessageAsync(htmlText: msg, disableNotification: false) { [weak self] _ in
                self?.notificationGroup.leave()
            }
            notificationGroup.enter()
            WebhookNotifier.shared.sendWebhookAsync(snapshot: snapshot, title: recoveryTitle, eventType: "health_recovered") { [weak self] _ in
                self?.notificationGroup.leave()
            }
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
                notificationGroup.enter()
                TelegramNotifier.shared.sendMessageAsync(htmlText: msg, disableNotification: true) { [weak self] _ in
                    self?.notificationGroup.leave()
                }
            }
        }
    }

    // MARK: - Volume Verification Delegation

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

        VolumeVerifierService.shared.runVolumeVerification(target: target) { [weak self] ok, summary in
            guard let self = self else { return }

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

    // MARK: - Custom Alert Script Execution Hook

    private let notificationGroup = DispatchGroup()

    func waitForPendingNotifications(timeout: TimeInterval = 3.0) {
        _ = notificationGroup.wait(timeout: .now() + timeout)
    }

    func testAlertScriptResult() -> Result<String, DiskHealthError> {
        let rawScriptPath = ConfigManager.shared.resolvedAlertScriptPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawScriptPath.isEmpty else {
            return .failure(.configurationInvalid(reason: "No alert script configured. Set alertScriptPath in Settings or via ALERT_SCRIPT_PATH environment variable."))
        }
        let expandedPath = (rawScriptPath as NSString).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: expandedPath) else {
            return .failure(.scriptNotExecutable(path: expandedPath))
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
                return .success("✅ Alert script executed successfully (exit code 0).\(outSuffix)")
            } else {
                return .failure(.scriptExecutionFailed(exitCode: proc.terminationStatus, output: "❌ Alert script failed with exit code \(proc.terminationStatus).\(outSuffix)"))
            }
        } catch {
            return .failure(.scriptExecutionFailed(exitCode: -1, output: "❌ Failed to execute alert script: \(error.localizedDescription)"))
        }
    }

    func testAlertScript() -> (ok: Bool, summary: String) {
        switch testAlertScriptResult() {
        case .success(let msg):
            return (true, msg)
        case .failure(let err):
            switch err {
            case .configurationInvalid(let reason):
                return (false, reason)
            case .scriptNotExecutable(let path):
                return (false, "Alert script is not executable: \(path)")
            case .scriptExecutionFailed(_, let output):
                return (false, output)
            default:
                return (false, err.localizedDescription)
            }
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

    // MARK: - Surface Read Scan Delegation

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
        return SurfaceScannerService.shared.runSurfaceReadScan(
            mountPoint: snap.mountPoint,
            totalBytes: snap.totalBytes,
            freeBytes: snap.freeBytes,
            mode: mode,
            maxBytesToScan: maxBytesToScan,
            cancellationToken: cancellationToken,
            progressHandler: progressHandler
        )
    }
}
