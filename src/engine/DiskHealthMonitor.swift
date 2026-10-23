// ============================================================================
// File: DiskHealthMonitor.swift
// Module: Layer 3 (Telemetry & Domain Engine)
// Purpose: Central coordinator for single-disk and fleet-wide storage evaluations,
//          throughput delta tracking, baseline state persistence, and alert dispatch.
// Concurrency: Thread-safe via NSRecursiveLock (engineLock). UI state synchronized
//              via Combine @Published on @MainActor.
// ============================================================================

import Foundation
import Darwin
import Combine
import AppKit

// MARK: - Types & Constants

/// Synchronized ISO 8601 date formatter for daily summary digest comparisons.
private let dailyDigestDateFormatter: SynchronizedDateFormatter = {
    let df = SynchronizedDateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.dateFormat = "yyyy-MM-dd"
    return df
}()

/// Primary telemetry coordinator orchestrating multi-disk evaluations,
/// active canary write/read probes, volume verification, and alert delivery.
final class DiskHealthMonitor: ObservableObject, @unchecked Sendable {
    /// Shared singleton instance.
    static let shared = DiskHealthMonitor()

    typealias SurfaceScanMode = SurfaceScannerService.SurfaceScanMode
    typealias SurfaceScanProgress = SurfaceScannerService.SurfaceScanProgress
    typealias SurfaceScanCancellationToken = SurfaceScannerService.SurfaceScanCancellationToken

    @Published private(set) var publishedSnapshot: DiskHealthSnapshot?
    private var latestSnapshotInternal: DiskHealthSnapshot?

    @Published private(set) var publishedMultiSnapshot: MultiDiskHealthSnapshot?
    private var latestMultiSnapshotInternal: MultiDiskHealthSnapshot?
    @Published var selectedDashboardDriveKey: String = ""
    private var selectedDashboardDriveKeyInternal: String = ""

    var currentSnapshot: DiskHealthSnapshot? {
        engineLock.lock()
        defer { engineLock.unlock() }
        return latestSnapshotInternal
    }

    var currentMultiSnapshot: MultiDiskHealthSnapshot? {
        engineLock.lock()
        defer { engineLock.unlock() }
        return latestMultiSnapshotInternal
    }

    @Published private(set) var isVerifyingVolume: Bool = false
    private var isVerifyingInternal: Bool = false

    private let engineLock = NSRecursiveLock()
    private var state: DiskPersistentState
    private var lastSavedState: DiskPersistentState?
    private var previousDriveKey: String = ""
    private var previousBytesRead: UInt64 = 0
    private var previousBytesWritten: UInt64 = 0
    private var previousSampleTime: TimeInterval = 0
    private var lastWakeTime: TimeInterval = 0
    private(set) var isSystemSleeping: Bool = false
    private var recentTemperatureSamples: [String: [(timestamp: TimeInterval, tempC: Int)]] = [:]
    private var defaultTelemetryProvider: any DiskTelemetryProvider = IOKitTelemetryProvider.shared

    private let prettyJSONEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private struct DriveThroughputSample {
        var bytesRead: UInt64 = 0
        var bytesWritten: UInt64 = 0
        var operationsRead: UInt64 = 0
        var operationsWritten: UInt64 = 0
        var totalTimeReadNs: UInt64 = 0
        var totalTimeWriteNs: UInt64 = 0
        var timestamp: TimeInterval = 0
    }
    private var throughputSamplesByDrive: [String: DriveThroughputSample] = [:]

    private init() {
        let loaded = DiskHealthMonitor.loadState()
        self.state = loaded
        self.lastSavedState = loaded
    }

    /// Switches the currently inspected drive in the Menu Bar popover and Settings tabs.
    ///
    /// - Parameter key: Unique drive identifier (`serialNumber`, `bsdName`, or `mountPoint`).
    /// - Note: Concurrency Optimization (SYS2-02): If invoked from the main UI thread,
    ///   updates `@Published` properties immediately for instantaneous UI responsiveness,
    ///   and dispatches `engineLock` synchronization asynchronously to a `.userInitiated`
    ///   background queue. This prevents the main AppKit run loop from beachballing
    ///   if a background poll is currently holding `engineLock` during `statfs` or `fsync`.
    func selectDashboardDrive(key: String) {
        let applySelectionToLock = { [weak self] in
            guard let self = self else { return }
            self.engineLock.lock()
            self.selectedDashboardDriveKeyInternal = key
            let matchingSnap = self.latestMultiSnapshotInternal?.disks.first(where: { $0.driveKey == key })
            if let matchingSnap = matchingSnap {
                self.latestSnapshotInternal = matchingSnap
            }
            self.engineLock.unlock()
            if let matchingSnap = matchingSnap {
                if Thread.isMainThread {
                    self.publishedSnapshot = matchingSnap
                } else {
                    DispatchQueue.main.async { [weak self] in
                        self?.publishedSnapshot = matchingSnap
                    }
                }
            }
        }

        if Thread.isMainThread {
            self.selectedDashboardDriveKey = key
            if let matching = self.publishedMultiSnapshot?.disks.first(where: { $0.driveKey == key }) {
                self.publishedSnapshot = matching
            }
            DispatchQueue.global(qos: .userInitiated).async(execute: applySelectionToLock)
        } else {
            applySelectionToLock()
            DispatchQueue.main.async { [weak self] in
                self?.selectedDashboardDriveKey = key
            }
        }
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

    private func saveStateLocked(force: Bool = false) {
        let path = ConfigManager.shared.stateFilePath
        let lockPath = "\(ConfigManager.shared.stateDir)/state.lock"
        let lockFd = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        if lockFd >= 0 {
            _ = flock(lockFd, LOCK_EX)
        }
        defer {
            if lockFd >= 0 {
                _ = flock(lockFd, LOCK_UN)
                close(lockFd)
            }
        }

        if !force, let last = lastSavedState, last == state, FileManager.default.fileExists(atPath: path) {
            return
        }
        if let data = try? prettyJSONEncoder.encode(state) {
            if AtomicFileWriter.writeRestricted(data: data, toPath: path, permissions: 0o600) {
                lastSavedState = state
            }
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
        self.latestMultiSnapshotInternal = nil
        self.throughputSamplesByDrive.removeAll()
        engineLock.unlock()
        if Thread.isMainThread {
            self.publishedSnapshot = nil
            self.publishedMultiSnapshot = nil
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.publishedSnapshot = nil
                self?.publishedMultiSnapshot = nil
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
        let activeSnapshots: [DiskHealthSnapshot] = {
            if let multi = self.latestMultiSnapshotInternal, !multi.disks.isEmpty {
                return multi.disks
            }
            if let single = self.latestSnapshotInternal {
                return [single]
            }
            return []
        }()
        if !activeSnapshots.isEmpty {
            for snap in activeSnapshots {
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
            }
        } else {
            for k in Array(self.state.drives.keys) {
                self.state.updateDriveState(key: k) { d in
                    // Retain known baseline error counts rather than wiping to nil (which would trigger immediate false alerts)
                    d.baselineUnsafeShutdowns = d.baselineUnsafeShutdowns ?? 0
                    d.baselineMediaErrors = d.baselineMediaErrors ?? 0
                    d.baselineErrorLogEntries = d.baselineErrorLogEntries ?? 0
                    d.baselineIoReadErrors = d.baselineIoReadErrors ?? 0
                    d.baselineIoWriteErrors = d.baselineIoWriteErrors ?? 0
                    d.baselineIoReadRetries = d.baselineIoReadRetries ?? 0
                    d.baselineIoWriteRetries = d.baselineIoWriteRetries ?? 0
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
                $0.consecutiveHealthyPolls = 0
                $0.consecutiveUnhealthyPolls = 0
                $0.lastNotifiedSeverity = HealthSeverity.healthy.rawValue
            }
        }
        self.state.lastOverallSeverity = HealthSeverity.healthy.rawValue
        self.state.lastAlertTimestampByCode.removeAll()
        self.recentTemperatureSamples.removeAll()
        saveStateLocked(force: true)
        ConfigManager.shared.log("Persistent baselines and health state reset for active fleet.")
    }

    // MARK: - Health Evaluation Pipeline

    private func evaluateSingleTargetLocked(
        targetMount: String,
        targetQuery: String,
        preloadedHardware: DiskHardwareMetrics?,
        isAutoDiscovered: Bool,
        forceCanary: Bool,
        allowNotifications: Bool,
        now: Date,
        nowTs: TimeInterval,
        formattedTime: String,
        formattedShortTime: String,
        cfg: DiskHealthConfig,
        provider: any DiskTelemetryProvider
    ) -> DiskHealthSnapshot {
        // 1. Hardware Telemetry Query
        let hw: DiskHardwareMetrics
        if let preloaded = preloadedHardware, preloaded.found {
            hw = preloaded
        } else {
            let queryToPass = !targetMount.isEmpty ? targetMount : (!targetQuery.isEmpty ? targetQuery : "auto")
            hw = provider.readHardwareMetrics(query: queryToPass)
        }

        let vendorName = hw.found ? cStringToSwift(hw.vendorName) : "Generic"
        let productName = hw.found ? cStringToSwift(hw.productName) : "Storage Device"
        let productRevision = hw.found ? cStringToSwift(hw.productRevision) : ""
        let bsdName = hw.found ? cStringToSwift(hw.bsdName) : ""
        let serialNumber = hw.found ? cStringToSwift(hw.serialNumber) : ""
        let interconnect = hw.found ? cStringToSwift(hw.interconnectType) : "Storage"
        let protocolType = hw.found ? cStringToSwift(hw.protocolType) : ""
        let linkSpeedFormatted = formatLinkSpeed(hw.linkSpeedBps, interconnect: interconnect)

        // 2. Resolve Mount Point for this Hardware Device if targetMount is not explicitly set
        var resolvedMount = targetMount
        if resolvedMount.isEmpty && hw.found && !bsdName.isEmpty {
            if let m = provider.findMountPoint(forBsdName: bsdName) {
                resolvedMount = m
            }
        }

        // 3. Mount & Filesystem Inspection
        var mountToInspect = !resolvedMount.isEmpty ? resolvedMount : (!targetQuery.isEmpty && targetQuery.starts(with: "/") ? targetQuery : "")
        if isAutoDiscovered && resolvedMount.isEmpty {
            mountToInspect = ""
        }
        let fsMetrics = provider.inspectFilesystem(mountPath: mountToInspect)
        // If an auto-discovered drive was unmounted/ejected mid-cycle between findMountPoint and statfs,
        // clear mountToInspect so it is treated as an unmounted physical disk rather than a missing target volume.
        if isAutoDiscovered && !fsMetrics.isMounted {
            mountToInspect = ""
        }

        // 4. Required Subpaths Check (scoped to explicitly configured target volume or single-disk mode)
        let shouldCheckSubpaths: Bool = {
            guard !mountToInspect.isEmpty && !cfg.requiredSubpaths.isEmpty else { return false }
            if !cfg.monitorAllDisks && cfg.monitoredTargets.count <= 1 { return true }
            if let configuredVol = cfg.targetVolumePath, !configuredVol.isEmpty {
                return fsMetrics.mountPoint == (configuredVol as NSString).standardizingPath
            }
            return false
        }()
        let subpathsStatus: [String: Bool]
        if !shouldCheckSubpaths {
            subpathsStatus = [:]
        } else {
            subpathsStatus = provider.checkSubpaths(
                mountPoint: fsMetrics.mountPoint,
                isMounted: fsMetrics.isMounted,
                requiredSubpaths: cfg.requiredSubpaths
            )
        }

        let driveKey: String = {
            if !serialNumber.isEmpty && !DiskHealthSnapshot.isPlaceholderSerial(serialNumber) {
                return serialNumber
            }
            if !serialNumber.isEmpty && !bsdName.isEmpty {
                return "\(serialNumber)#\(bsdName)"
            }
            if !bsdName.isEmpty { return bsdName }
            if !resolvedMount.isEmpty { return resolvedMount }
            if !targetQuery.isEmpty { return targetQuery }
            return "default"
        }()

        // 5. Active I/O Canary Probe
        var canaryOk = false
        var canaryLatencyMs = 0.0
        var canaryError = fsMetrics.isMounted ? "Canary disabled" : "Volume not mounted"
        if fsMetrics.isMounted && cfg.enableActiveCanary {
            if isSystemSleeping {
                canaryOk = true
                canaryError = "Suppressed while system is sleeping"
            } else {
                let res = provider.runCanaryProbe(targetMount: fsMetrics.mountPoint, force: forceCanary, nowTs: nowTs)
                canaryOk = res.ok
                canaryLatencyMs = res.latencyMs
                canaryError = res.error
                // Guard against mid-probe unmount/ejection of an auto-discovered external drive
                if !canaryOk && isAutoDiscovered {
                    let postCheck = provider.inspectFilesystem(mountPath: fsMetrics.mountPoint)
                    if !postCheck.isMounted {
                        canaryOk = true
                        canaryError = "Volume unmounted during probe"
                    }
                }
            }
        }

        // 6. Throughput & Latency Calculations (tracked per driveKey)
        var readMBps = 0.0
        var writeMBps = 0.0
        var intervalReadLatMs = 0.0
        var intervalWriteLatMs = 0.0
        var hasIntervalLatency = false

        if hw.statsValid {
            if let prev = throughputSamplesByDrive[driveKey], prev.timestamp > 0 && nowTs > prev.timestamp {
                let dt = nowTs - prev.timestamp
                if hw.bytesRead >= prev.bytesRead {
                    readMBps = Double(hw.bytesRead - prev.bytesRead) / (1_000_000.0 * dt)
                }
                if hw.bytesWritten >= prev.bytesWritten {
                    writeMBps = Double(hw.bytesWritten - prev.bytesWritten) / (1_000_000.0 * dt)
                }
                if hw.operationsRead >= prev.operationsRead && hw.totalTimeReadNs >= prev.totalTimeReadNs {
                    let deltaOpsR = hw.operationsRead - prev.operationsRead
                    let deltaTimeNsR = hw.totalTimeReadNs - prev.totalTimeReadNs
                    if deltaOpsR >= 50 {
                        intervalReadLatMs = Double(deltaTimeNsR) / Double(deltaOpsR) / 1_000_000.0
                        hasIntervalLatency = true
                    }
                }
                if hw.operationsWritten >= prev.operationsWritten && hw.totalTimeWriteNs >= prev.totalTimeWriteNs {
                    let deltaOpsW = hw.operationsWritten - prev.operationsWritten
                    let deltaTimeNsW = hw.totalTimeWriteNs - prev.totalTimeWriteNs
                    if deltaOpsW >= 50 {
                        intervalWriteLatMs = Double(deltaTimeNsW) / Double(deltaOpsW) / 1_000_000.0
                        hasIntervalLatency = true
                    }
                }
            }
            throughputSamplesByDrive[driveKey] = DriveThroughputSample(
                bytesRead: hw.bytesRead,
                bytesWritten: hw.bytesWritten,
                operationsRead: hw.operationsRead,
                operationsWritten: hw.operationsWritten,
                totalTimeReadNs: hw.totalTimeReadNs,
                totalTimeWriteNs: hw.totalTimeWriteNs,
                timestamp: nowTs
            )
        }

        let avgReadLatMs = hasIntervalLatency ? intervalReadLatMs : ((hw.statsValid && hw.operationsRead > 0)
            ? (Double(hw.totalTimeReadNs) / Double(hw.operationsRead) / 1_000_000.0)
            : 0.0)
        let avgWriteLatMs = hasIntervalLatency ? intervalWriteLatMs : ((hw.statsValid && hw.operationsWritten > 0)
            ? (Double(hw.totalTimeWriteNs) / Double(hw.operationsWritten) / 1_000_000.0)
            : 0.0)

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

            // Re-baseline on counter decrease (controller reset / firmware refresh)
            if let prevMedia = driveState.baselineMediaErrors, hw.mediaErrors < prevMedia {
                driveState.baselineMediaErrors = hw.mediaErrors
            }
            if let prevLog = driveState.baselineErrorLogEntries, hw.errorInfoLogEntries < prevLog {
                driveState.baselineErrorLogEntries = hw.errorInfoLogEntries
            }
        }
        if hw.statsValid {
            if driveState.baselineIoReadErrors == nil { driveState.baselineIoReadErrors = 0 }
            if driveState.baselineIoWriteErrors == nil { driveState.baselineIoWriteErrors = 0 }
            if driveState.baselineIoReadRetries == nil { driveState.baselineIoReadRetries = hw.retriesRead }
            if driveState.baselineIoWriteRetries == nil { driveState.baselineIoWriteRetries = hw.retriesWritten }

            // Re-baseline on driver stats counter reset (system reboot / drive replug)
            if let prevR = driveState.baselineIoReadErrors, hw.errorsRead < prevR {
                driveState.baselineIoReadErrors = hw.errorsRead
            }
            if let prevW = driveState.baselineIoWriteErrors, hw.errorsWritten < prevW {
                driveState.baselineIoWriteErrors = hw.errorsWritten
            }
            if let prevRetR = driveState.baselineIoReadRetries, hw.retriesRead < prevRetR {
                driveState.baselineIoReadRetries = hw.retriesRead
            }
            if let prevRetW = driveState.baselineIoWriteRetries, hw.retriesWritten < prevRetW {
                driveState.baselineIoWriteRetries = hw.retriesWritten
            }
        }

        if fsMetrics.isMounted && !fsMetrics.isReadOnly {
            driveState.wasWritable = true
        }

        state.drives[driveKey] = driveState

        // 8. Evaluate Health Rules Pipeline
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

        if allowNotifications {
            processAlertsAndDigestLocked(snapshot: snapshot, rawMetrics: hw, driveKey: driveKey)
        }

        // Check if scheduled background volume verification is due
        if allowNotifications && !isSystemSleeping && !isVerifyingInternal && cfg.scheduledVerifyIntervalHours > 0 && fsMetrics.isMounted {
            let intervalSec = Double(cfg.scheduledVerifyIntervalHours) * 3600.0
            if (nowTs - driveState.lastVerifyTimestamp) >= intervalSec {
                let scheduledMount = fsMetrics.mountPoint
                let scheduledDriveKey = driveKey
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    self?.runVolumeVerification(targetMountOverride: scheduledMount, driveKeyOverride: scheduledDriveKey, sendTelegram: true)
                }
            }
        }

        return snapshot
    }

    static func isValidUniqueSerial(_ s: String) -> Bool {
        let clean = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != "0", clean != "N/A", clean != "None", clean != "0123456789ABCDEF" else { return false }
        if clean.allSatisfy({ $0 == "0" || $0 == " " || $0 == "-" || $0 == "_" }) { return false }
        return true
    }

    /// Evaluates health, performance, and SMART telemetry across all monitored physical storage devices.
    ///
    /// - Parameters:
    ///   - forceCanary: If true, forces an immediate active 512B write probe bypassing the 300s cache.
    ///   - allowNotifications: If true, dispatches alert notifications for detected issues violating cooldowns.
    ///   - persistState: If true, saves state.json and latest_status.json (false for read-only CLI calls).
    ///   - telemetryProvider: Optional custom telemetry provider (used for unit test fault injection).
    /// - Returns: Aggregated `MultiDiskHealthSnapshot` summarizing fleet health and per-drive metrics.
    /// - Note: Concurrency: Synchronized via `engineLock`. Dispatches `@Published` updates to main thread.
    @discardableResult
    func evaluateAllMonitoredDisks(
        forceCanary: Bool = false,
        allowNotifications: Bool = true,
        persistState: Bool = true,
        telemetryProvider: (any DiskTelemetryProvider)? = nil
    ) -> MultiDiskHealthSnapshot {
        engineLock.lock()
        defer { engineLock.unlock() }

        let provider = telemetryProvider ?? self.defaultTelemetryProvider
        let now = Date()
        let nowTs = now.timeIntervalSince1970
        let formattedTime = isoTimestampFormatter.string(from: now)
        let formattedShortTime = shortTimeFormatter.string(from: now)
        let cfg = ConfigManager.shared.currentConfig

        var snapshots: [DiskHealthSnapshot] = []

        if cfg.monitorAllDisks {
            let all = provider.listAllDevices(maxCount: 32)
            var serialCounts: [String: Int] = [:]
            for dev in all where dev.found {
                let ser = cStringToSwift(dev.serialNumber).trimmingCharacters(in: .whitespacesAndNewlines)
                if DiskHealthMonitor.isValidUniqueSerial(ser) {
                    serialCounts[ser, default: 0] += 1
                }
            }

            var seenKeys = Set<String>()
            var enumeratedDevices: [DiskHardwareMetrics] = []
            enumeratedDevices.reserveCapacity(all.count)
            for dev in all where dev.found {
                let ser = cStringToSwift(dev.serialNumber).trimmingCharacters(in: .whitespacesAndNewlines)
                let bsd = cStringToSwift(dev.bsdName).trimmingCharacters(in: .whitespacesAndNewlines)
                let key: String
                if DiskHealthMonitor.isValidUniqueSerial(ser) && (serialCounts[ser] ?? 0) == 1 {
                    key = ser
                } else if DiskHealthMonitor.isValidUniqueSerial(ser) {
                    key = "\(ser)#\(bsd)"
                } else {
                    key = bsd
                }
                if key.isEmpty || !seenKeys.contains(key) {
                    if !key.isEmpty { seenKeys.insert(key) }
                    enumeratedDevices.append(dev)
                }
            }

            if !enumeratedDevices.isEmpty {
                for dev in enumeratedDevices {
                    let bsd = cStringToSwift(dev.bsdName)
                    let snap = evaluateSingleTargetLocked(
                        targetMount: "",
                        targetQuery: bsd,
                        preloadedHardware: dev,
                        isAutoDiscovered: true,
                        forceCanary: forceCanary,
                        allowNotifications: allowNotifications,
                        now: now,
                        nowTs: nowTs,
                        formattedTime: formattedTime,
                        formattedShortTime: formattedShortTime,
                        cfg: cfg,
                        provider: provider
                    )
                    snapshots.append(snap)
                }
            } else {
                let snap = evaluateSingleTargetLocked(
                    targetMount: cfg.targetVolumePath ?? "",
                    targetQuery: cfg.targetDeviceQuery ?? "",
                    preloadedHardware: nil,
                    isAutoDiscovered: false,
                    forceCanary: forceCanary,
                    allowNotifications: allowNotifications,
                    now: now,
                    nowTs: nowTs,
                    formattedTime: formattedTime,
                    formattedShortTime: formattedShortTime,
                    cfg: cfg,
                    provider: provider
                )
                snapshots.append(snap)
            }
        } else if !cfg.monitoredTargets.isEmpty {
            for target in cfg.monitoredTargets {
                let isMount = target.hasPrefix("/")
                let snap = evaluateSingleTargetLocked(
                    targetMount: isMount ? target : "",
                    targetQuery: isMount ? "" : target,
                    preloadedHardware: nil,
                    isAutoDiscovered: false,
                    forceCanary: forceCanary,
                    allowNotifications: allowNotifications,
                    now: now,
                    nowTs: nowTs,
                    formattedTime: formattedTime,
                    formattedShortTime: formattedShortTime,
                    cfg: cfg,
                    provider: provider
                )
                snapshots.append(snap)
            }
        } else {
            let snap = evaluateSingleTargetLocked(
                targetMount: cfg.targetVolumePath ?? "",
                targetQuery: cfg.targetDeviceQuery ?? "",
                preloadedHardware: nil,
                isAutoDiscovered: false,
                forceCanary: forceCanary,
                allowNotifications: allowNotifications,
                now: now,
                nowTs: nowTs,
                formattedTime: formattedTime,
                formattedShortTime: formattedShortTime,
                cfg: cfg,
                provider: provider
            )
            snapshots.append(snap)
        }

        // Safe fallback if target filtering yielded 0 snapshots (eliminates force unwrap trap)
        if snapshots.isEmpty {
            let fallback = evaluateSingleTargetLocked(
                targetMount: cfg.targetVolumePath ?? "",
                targetQuery: cfg.targetDeviceQuery ?? "",
                preloadedHardware: nil,
                isAutoDiscovered: false,
                forceCanary: forceCanary,
                allowNotifications: allowNotifications,
                now: now,
                nowTs: nowTs,
                formattedTime: formattedTime,
                formattedShortTime: formattedShortTime,
                cfg: cfg,
                provider: provider
            )
            snapshots.append(fallback)
        }

        var worstSeverity: HealthSeverity = .healthy
        var worstScore: Int = snapshots.isEmpty ? 100 : Int.max
        var scoreSum: Int = 0
        var totalIssues: Int = 0
        for snap in snapshots {
            if snap.overallSeverity.rank > worstSeverity.rank {
                worstSeverity = snap.overallSeverity
            }
            if snap.healthScore < worstScore {
                worstScore = snap.healthScore
            }
            scoreSum += snap.healthScore
            totalIssues += snap.issues.count
        }
        let avgScore = snapshots.isEmpty ? 100 : (scoreSum / snapshots.count)

        let multi = MultiDiskHealthSnapshot(
            timestamp: nowTs,
            formattedTime: formattedTime,
            formattedShortTime: formattedShortTime,
            overallSeverity: worstSeverity,
            worstHealthScore: worstScore,
            averageHealthScore: avgScore,
            totalIssuesCount: totalIssues,
            disks: snapshots
        )

        self.latestMultiSnapshotInternal = multi
        self.state.lastOverallSeverity = worstSeverity.rawValue

        if selectedDashboardDriveKeyInternal.isEmpty || !snapshots.contains(where: { $0.driveKey == selectedDashboardDriveKeyInternal }) {
            selectedDashboardDriveKeyInternal = multi.primarySnapshot?.driveKey ?? snapshots.first?.driveKey ?? ""
        }
        let resolvedSelectedKey = selectedDashboardDriveKeyInternal
        let primary = snapshots.first(where: { $0.driveKey == resolvedSelectedKey }) ?? multi.primarySnapshot ?? snapshots[0]
        self.latestSnapshotInternal = primary

        if persistState {
            // Save latest_status.json (single disk writes primary for full backward compatibility, multi writes multi)
            if multi.disks.count > 1 {
                if let jsonData = try? prettyJSONEncoder.encode(multi) {
                    _ = AtomicFileWriter.writeRestricted(data: jsonData, toPath: ConfigManager.shared.latestJsonPath, permissions: 0o600)
                }
            } else {
                if let jsonData = try? prettyJSONEncoder.encode(primary) {
                    _ = AtomicFileWriter.writeRestricted(data: jsonData, toPath: ConfigManager.shared.latestJsonPath, permissions: 0o600)
                }
            }

            saveStateLocked()
        }

        if Thread.isMainThread {
            if self.selectedDashboardDriveKey != resolvedSelectedKey {
                self.selectedDashboardDriveKey = resolvedSelectedKey
            }
            self.publishedMultiSnapshot = multi
            self.publishedSnapshot = primary
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if self.selectedDashboardDriveKey != resolvedSelectedKey {
                    self.selectedDashboardDriveKey = resolvedSelectedKey
                }
                self.publishedMultiSnapshot = multi
                self.publishedSnapshot = primary
            }
        }

        return multi
    }

    /// Backward-compatible single-drive evaluation returning the snapshot of the selected drive.
    ///
    /// - Parameters:
    ///   - forceCanary: If true, forces an immediate active 512B write probe bypassing the 300s cache.
    ///   - allowNotifications: If true, dispatches alert notifications for detected issues violating cooldowns.
    ///   - persistState: If true, saves state.json and latest_status.json (false for read-only CLI calls).
    ///   - telemetryProvider: Optional custom telemetry provider (used for unit test fault injection).
    /// - Returns: `DiskHealthSnapshot` of the currently selected or primary dashboard drive.
    @discardableResult
    func evaluateHealth(
        forceCanary: Bool = false,
        allowNotifications: Bool = true,
        persistState: Bool = true,
        telemetryProvider: (any DiskTelemetryProvider)? = nil
    ) -> DiskHealthSnapshot {
        let multi = evaluateAllMonitoredDisks(
            forceCanary: forceCanary,
            allowNotifications: allowNotifications,
            persistState: persistState,
            telemetryProvider: telemetryProvider
        )
        return self.latestSnapshotInternal ?? multi.primarySnapshot ?? multi.disks[0]
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
            if snapshot.issues.contains(where: { $0.code == "IO_DRIVER_ERRORS" }) && hw.statsValid {
                self.state.updateDriveState(key: driveKey) {
                    $0.baselineIoReadErrors = hw.errorsRead
                    $0.baselineIoWriteErrors = hw.errorsWritten
                }
            }
            if snapshot.issues.contains(where: { $0.code == "MEDIA_ERRORS" }) && hw.smartValid {
                self.state.updateDriveState(key: driveKey) {
                    $0.baselineMediaErrors = hw.mediaErrors
                }
            }

            self.state.updateDriveState(key: driveKey) {
                $0.consecutiveUnhealthyPolls += 1
                $0.consecutiveHealthyPolls = 0
                $0.lastNotifiedSeverity = snapshot.overallSeverity.rawValue
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
        } else if snapshot.overallSeverity == .healthy {
            var driveState = self.state.getDriveState(key: driveKey)
            driveState.consecutiveHealthyPolls += 1
            driveState.consecutiveUnhealthyPolls = 0

            let previouslyAlerted = driveState.lastNotifiedSeverity != HealthSeverity.healthy.rawValue
            if previouslyAlerted && driveState.consecutiveHealthyPolls >= 2 {
                let recoveryTitle = "\(snapshot.productName) RECOVERED — HEALTHY"
                ConfigManager.shared.log("Drive \(driveKey) recovered to HEALTHY state.")
                driveState.lastNotifiedSeverity = HealthSeverity.healthy.rawValue
                driveState.lastRecoveryTimestamp = nowTs

                // Recovery hold: retain cooldowns older than 900s, preventing rapid flapping alert spam
                let prefix = "\(driveKey):"
                for key in Array(state.lastAlertTimestampByCode.keys) where key.hasPrefix(prefix) || !key.contains(":") {
                    let ts = state.lastAlertTimestampByCode[key] ?? 0
                    if (nowTs - ts) > 900.0 {
                        state.lastAlertTimestampByCode.removeValue(forKey: key)
                    }
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
            state.drives[driveKey] = driveState
        }

        state.updateDriveState(key: driveKey) {
            $0.lastOverallSeverity = snapshot.overallSeverity.rawValue
        }

        // Daily Digest at 09:00 (Per-Drive Scoped)
        if state.dailySummaryEnabled {
            let digestScopedKey = "\(driveKey):DAILY_DIGEST"
            let lastDigestTs = state.lastAlertTimestampByCode[digestScopedKey] ?? 0
            if lastDigestTs == 0 {
                state.lastAlertTimestampByCode[digestScopedKey] = nowTs
                if state.lastDailySummaryDate.isEmpty {
                    state.lastDailySummaryDate = dailyDigestDateFormatter.string(from: Date(timeIntervalSince1970: nowTs))
                }
            } else if (nowTs - lastDigestTs) >= 20 * 3600 {
                let nowDate = Date(timeIntervalSince1970: nowTs)
                if Calendar.current.component(.hour, from: nowDate) >= 9 {
                    state.lastDailySummaryDate = dailyDigestDateFormatter.string(from: nowDate)
                    state.lastAlertTimestampByCode[digestScopedKey] = nowTs
                    let msg = TelegramNotifier.shared.formatReportHTML(snapshot: snapshot, title: "\(snapshot.productName) Daily Health Digest")
                    notificationGroup.enter()
                    TelegramNotifier.shared.sendMessageAsync(htmlText: msg, disableNotification: true) { [weak self] _ in
                        self?.notificationGroup.leave()
                    }
                }
            }
        }
    }

    // MARK: - Volume Verification Delegation

    func runVolumeVerification(
        targetMountOverride: String? = nil,
        driveKeyOverride: String? = nil,
        sendTelegram: Bool = true,
        completion: ((Bool, String) -> Void)? = nil
    ) {
        engineLock.lock()
        if isVerifyingInternal {
            engineLock.unlock()
            completion?(false, "Verification already in progress")
            return
        }
        let snap = self.currentSnapshot ?? self.evaluateHealth(forceCanary: false, allowNotifications: false)
        let snapMount = snap.mountPoint
        let cfgVol = ConfigManager.shared.currentConfig.targetVolumePath ?? ""
        let target = targetMountOverride ?? (!snapMount.isEmpty ? snapMount : (!cfgVol.isEmpty ? cfgVol : (!snap.bsdName.isEmpty ? "/dev/\(snap.bsdName)" : "/")))
        let capturedDriveKey = driveKeyOverride ?? (!snap.serialNumber.isEmpty
            ? snap.serialNumber
            : (!snap.bsdName.isEmpty ? snap.bsdName : (target.isEmpty ? "default" : target)))
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
            if sendTelegram && !summary.starts(with: "Skipped") {
                let title: String
                if summary.starts(with: "Verified OK") {
                    title = "\(updatedSnap.productName) File System Verification Passed"
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

    func waitForPendingNotifications(timeout: TimeInterval = 16.0) {
        _ = notificationGroup.wait(timeout: .now() + timeout)
    }

    private static func makeCleanAlertScriptEnvironment(snapshot: DiskHealthSnapshot, title: String, eventType: String) -> [String: String] {
        var env: [String: String] = [:]
        let safeKeys = ["PATH", "HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "SHELL", "TMPDIR"]
        let currentEnv = ProcessInfo.processInfo.environment
        for k in safeKeys {
            if let val = currentEnv[k] { env[k] = val }
        }
        if env["PATH"] == nil {
            env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        }
        env["DISK_HEALTH_EVENT"] = eventType
        env["DISK_HEALTH_TITLE"] = title
        env["DISK_HEALTH_SEVERITY"] = snapshot.overallSeverity.rawValue
        env["DISK_HEALTH_SCORE"] = "\(snapshot.healthScore)"
        env["DISK_HEALTH_DEVICE"] = "\(snapshot.vendorName) \(snapshot.productName)".trimmingCharacters(in: .whitespaces)
        env["DISK_HEALTH_BSD_NAME"] = snapshot.bsdName
        env["DISK_HEALTH_MOUNT_POINT"] = snapshot.mountPoint
        env["DISK_HEALTH_TEMP_C"] = "\(snapshot.temperatureCelsius)"
        env["DISK_HEALTH_ISSUES"] = snapshot.issues.map { "[\($0.code)] \($0.title)" }.joined(separator: "; ")
        return env
    }

    /// Executes the user-configured alert script synchronously with a timeout watchdog.
    ///
    /// - Parameter timeoutSec: Watchdog duration in seconds (default 15.0s).
    /// - Returns: Success with stdout/stderr output, or DiskHealthError.
    /// - Note: Invariant (PROC-PIPE-01): Strips sensitive secrets (TELEGRAM_BOT_TOKEN, WEBHOOK_URL)
    ///   from child process environment and drains pipe file handle to prevent buffer deadlock.
    func testAlertScriptResult(timeoutSec: TimeInterval = 15.0) -> Result<String, DiskHealthError> {
        let rawScriptPath = ConfigManager.shared.resolvedAlertScriptPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawScriptPath.isEmpty else {
            return .failure(.configurationInvalid(reason: "No alert script configured. Set alertScriptPath in Settings or via ALERT_SCRIPT_PATH environment variable."))
        }
        let expandedPath = (rawScriptPath as NSString).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: expandedPath) else {
            return .failure(.scriptNotExecutable(path: expandedPath))
        }
        guard ConfigManager.isSecureUserOwnedFile(atPath: expandedPath) else {
            return .failure(.configurationInvalid(reason: "Alert script '\(expandedPath)' must be owned by current user (or root) and not group/world-writable."))
        }

        let snap = self.currentSnapshot ?? self.evaluateHealth(forceCanary: false, allowNotifications: false, persistState: false)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: expandedPath)
        let pipeOut = Pipe()
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = pipeOut
        proc.standardError = pipeOut
        let readHandle = pipeOut.fileHandleForReading

        proc.environment = DiskHealthMonitor.makeCleanAlertScriptEnvironment(snapshot: snap, title: "\(snap.productName) Alert Script Test", eventType: "test_alert")

        do {
            try proc.run()
            let pid = proc.processIdentifier
            let timeoutLock = NSLock()
            var timedOut = false
            var killWorkItem: DispatchWorkItem?
            let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            watchdog.schedule(deadline: .now() + timeoutSec)
            watchdog.setEventHandler {
                if proc.isRunning {
                    timeoutLock.lock()
                    timedOut = true
                    timeoutLock.unlock()
                    VolumeVerifierService.terminateProcessAndChildren(pid: pid, signal: SIGTERM)
                    proc.terminate()
                    let escalation = DispatchWorkItem {
                        if pid > 0 {
                            VolumeVerifierService.terminateProcessAndChildren(pid: pid, signal: SIGKILL)
                        }
                    }
                    timeoutLock.lock()
                    killWorkItem = escalation
                    timeoutLock.unlock()
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0, execute: escalation)
                }
            }
            watchdog.resume()

            let outputData = (try? readHandle.readToEnd()) ?? Data()
            proc.waitUntilExit()
            watchdog.cancel()
            timeoutLock.lock()
            killWorkItem?.cancel()
            let didTimeout = timedOut
            timeoutLock.unlock()
            try? readHandle.close()

            let outputStr = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let outSuffix = outputStr.isEmpty ? "" : "\n\(outputStr)"
            if didTimeout {
                return .failure(.scriptExecutionFailed(exitCode: -1, output: "❌ Alert script timed out after \(Int(timeoutSec))s.\(outSuffix)"))
            }
            if proc.terminationStatus == 0 {
                return .success("✅ Alert script executed successfully (exit code 0).\(outSuffix)")
            } else {
                return .failure(.scriptExecutionFailed(exitCode: proc.terminationStatus, output: "❌ Alert script failed with exit code \(proc.terminationStatus).\(outSuffix)"))
            }
        } catch {
            try? readHandle.close()
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
        guard ConfigManager.isSecureUserOwnedFile(atPath: expandedPath) else {
            ConfigManager.shared.log("Alert script skipped (insecure permissions/ownership): \(expandedPath)")
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
            proc.environment = DiskHealthMonitor.makeCleanAlertScriptEnvironment(snapshot: snapshot, title: title, eventType: eventType)

            do {
                try proc.run()
                let pid = proc.processIdentifier
                let timeoutLock = NSLock()
                var killWorkItem: DispatchWorkItem?
                let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
                watchdog.schedule(deadline: .now() + 15.0)
                watchdog.setEventHandler {
                    if proc.isRunning {
                        VolumeVerifierService.terminateProcessAndChildren(pid: pid, signal: SIGTERM)
                        proc.terminate()
                        let escalation = DispatchWorkItem {
                            if proc.isRunning && pid > 0 {
                                VolumeVerifierService.terminateProcessAndChildren(pid: pid, signal: SIGKILL)
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
