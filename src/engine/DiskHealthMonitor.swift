// ============================================================================
// File: DiskHealthMonitor.swift
// Module: Layer 3 (Telemetry & Domain Engine)
// Purpose: Central coordinator for single-disk and fleet-wide storage evaluations,
//          throughput delta tracking, health rule evaluation, and scan/verify dispatch.
// Concurrency: Unlocked Phase A (IOKit + ParallelDriveProber I/O) followed by
//              Phase B under NSRecursiveLock (`engineLock`). UI state published on main.
// ============================================================================

import Foundation
import Darwin
import Combine
import AppKit

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

    private let snapshotLock = NSLock()

    var currentSnapshot: DiskHealthSnapshot? {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return latestSnapshotInternal
    }

    var currentMultiSnapshot: MultiDiskHealthSnapshot? {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return latestMultiSnapshotInternal
    }

    @Published private(set) var isVerifyingVolume: Bool = false
    private var isVerifyingInternal: Bool = false
    @Published private(set) var publishedActionLog: [ActionExecutionRecord] = []

    private let engineLock = NSRecursiveLock()
    private var state: DiskPersistentState
    private var lastSavedState: DiskPersistentState?
    private var lastWakeTime: TimeInterval = 0
    private(set) var isSystemSleeping: Bool = false
    private var recentTemperatureSamples: [String: [(timestamp: TimeInterval, tempC: Int)]] = [:]
    private var defaultTelemetryProvider: any DiskTelemetryProvider = IOKitTelemetryProvider.shared

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

    private struct PreparedTargetInput {
        let targetMount: String
        let targetQuery: String
        let driveKeyHint: String
        let disambiguatedDriveKey: String?
        let hardware: DiskHardwareMetrics
        let mountToInspect: String
        let isAutoDiscovered: Bool
        let shouldCheckSubpaths: Bool
    }

    private struct PreparedTargetTelemetry {
        let targetMount: String
        let targetQuery: String
        let disambiguatedDriveKey: String?
        let hardware: DiskHardwareMetrics
        let mountToInspect: String
        let isAutoDiscovered: Bool
        let fsMetrics: FilesystemMountMetrics
        let subpathsStatus: [String: Bool]
        let apfsContainer: ApfsContainerFleetMetrics?
        let canaryOk: Bool
        let canaryLatencyMs: Double
        let canaryError: String
        let isQuarantined: Bool
    }

    private init() {
        let loaded = PersistentStateStore.loadState()
        self.state = loaded
        self.lastSavedState = loaded
        self.publishedActionLog = loaded.recentActionExecutions
    }

    /// Switches the currently inspected drive in the Menu Bar popover and Settings tabs.
    func selectDashboardDrive(key: String) {
        let applySelectionToLock = { [weak self] in
            guard let self = self else { return }
            self.snapshotLock.lock()
            self.selectedDashboardDriveKeyInternal = key
            let matchingSnap = self.latestMultiSnapshotInternal?.disks.first(where: { $0.driveKey == key })
            if let matchingSnap = matchingSnap {
                self.latestSnapshotInternal = matchingSnap
            }
            self.snapshotLock.unlock()
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
        PersistentStateStore.loadState()
    }

    private func saveStateLocked(force: Bool = false) {
        PersistentStateStore.saveState(self.state, lastSavedState: &self.lastSavedState, force: force)
    }

    func recordActionExecutions(_ records: [ActionExecutionRecord]) {
        guard !records.isEmpty else { return }
        engineLock.lock()
        defer { engineLock.unlock() }
        for rec in records {
            ActionRuleEngine.shared.appendAuditRecord(rec, to: &self.state)
        }
        saveStateLocked()
    }

    // MARK: - System Lifecycle & Sleep/Wake Management

    func noteSystemWillSleep() {
        engineLock.lock()
        if isSystemSleeping {
            engineLock.unlock()
            return
        }
        isSystemSleeping = true
        engineLock.unlock()

        let disksToNotify: [DiskHealthSnapshot] = {
            snapshotLock.lock()
            defer { snapshotLock.unlock() }
            if let multi = self.latestMultiSnapshotInternal {
                return multi.disks
            }
            if let single = self.latestSnapshotInternal {
                return [single]
            }
            return []
        }()

        ConfigManager.shared.log("System entering sleep; pausing telemetry deltas and running pre-sleep rules.")
        for disk in disksToNotify {
            _ = ActionRuleEngine.shared.triggerSystemWillSleepRules(for: disk)
        }
    }

    func noteSystemDidWake(at timestamp: TimeInterval = Date().timeIntervalSince1970) {
        engineLock.lock()
        isSystemSleeping = false
        lastWakeTime = timestamp
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
        snapshotLock.lock()
        self.latestSnapshotInternal = nil
        self.latestMultiSnapshotInternal = nil
        snapshotLock.unlock()
        engineLock.lock()
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
            CanaryProbeService.shared.resetCache()
        }
        saveStateLocked()
        engineLock.unlock()
    }

    func resetBaselines() {
        engineLock.lock()
        defer { engineLock.unlock() }
        let activeSnapshots: [DiskHealthSnapshot] = {
            snapshotLock.lock()
            defer { snapshotLock.unlock() }
            if let multi = self.latestMultiSnapshotInternal, !multi.disks.isEmpty {
                return multi.disks
            }
            if let single = self.latestSnapshotInternal {
                return [single]
            }
            return []
        }()
        PersistentStateStore.resetBaselines(in: &self.state, activeSnapshots: activeSnapshots)
        self.recentTemperatureSamples.removeAll()
        saveStateLocked(force: true)
        ConfigManager.shared.log("Persistent baselines and health state reset for active fleet.")
    }

    // MARK: - Phase A Unlocked Telemetry Collection

    private func applyTransientSmartRecovery(
        _ hw: inout DiskHardwareMetrics,
        prevMulti: MultiDiskHealthSnapshot?,
        prevSingle: DiskHealthSnapshot?,
        nowTs: TimeInterval
    ) {
        guard hw.found, (!hw.smartValid || hw.temperatureCelsius <= 0) else { return }
        let bsdName = cStringToSwift(hw.bsdName)
        let serialNumber = cStringToSwift(hw.serialNumber)
        let prevSnap = prevMulti?.disks.first(where: {
            (!bsdName.isEmpty && $0.bsdName == bsdName) ||
            (!serialNumber.isEmpty && $0.serialNumber == serialNumber)
        }) ?? prevSingle
        guard let prev = prevSnap, prev.smartValid, prev.temperatureCelsius > 0, (nowTs - prev.timestamp) < 15.0 else {
            return
        }
        hw.smartValid = true
        hw.temperatureCelsius = Int32(prev.temperatureCelsius)
        hw.temperatureKelvin = Int32(prev.temperatureKelvin)
        hw.criticalWarning = prev.criticalWarning
        hw.availableSpare = prev.availableSpare
        hw.availableSpareThreshold = prev.availableSpareThreshold
        hw.percentageUsed = prev.percentageUsed
        if hw.dataUnitsRead == 0 { hw.dataUnitsRead = prev.dataUnitsRead }
        if hw.dataUnitsWritten == 0 { hw.dataUnitsWritten = prev.dataUnitsWritten }
        if hw.powerCycles == 0 { hw.powerCycles = prev.powerCycles }
        if hw.powerOnHours == 0 { hw.powerOnHours = prev.powerOnHours }
        if hw.unsafeShutdowns == 0 { hw.unsafeShutdowns = prev.unsafeShutdowns }
        if hw.mediaErrors == 0 { hw.mediaErrors = prev.mediaErrors }
        if hw.errorInfoLogEntries == 0 { hw.errorInfoLogEntries = prev.errorInfoLogEntries }
    }

    private func shouldCheckSubpaths(cfg: DiskHealthConfig, mountPoint: String) -> Bool {
        guard !mountPoint.isEmpty && !cfg.requiredSubpaths.isEmpty else { return false }
        if !cfg.monitorAllDisks && cfg.monitoredTargets.count <= 1 { return true }
        if let configuredVol = cfg.targetVolumePath, !configuredVol.isEmpty {
            return mountPoint == (configuredVol as NSString).standardizingPath
        }
        return false
    }

    private func prepareInput(
        targetMount: String,
        targetQuery: String,
        disambiguatedDriveKey: String?,
        preloadedHardware: DiskHardwareMetrics?,
        isAutoDiscovered: Bool,
        cfg: DiskHealthConfig,
        provider: any DiskTelemetryProvider,
        prevMulti: MultiDiskHealthSnapshot?,
        prevSingle: DiskHealthSnapshot?,
        nowTs: TimeInterval
    ) -> PreparedTargetInput {
        var hw: DiskHardwareMetrics
        if let preloaded = preloadedHardware, preloaded.found {
            hw = preloaded
        } else {
            let queryToPass = !targetMount.isEmpty ? targetMount : (!targetQuery.isEmpty ? targetQuery : "auto")
            hw = provider.readHardwareMetrics(query: queryToPass)
        }
        applyTransientSmartRecovery(&hw, prevMulti: prevMulti, prevSingle: prevSingle, nowTs: nowTs)

        let bsdName = hw.found ? cStringToSwift(hw.bsdName) : ""
        var resolvedMount = targetMount
        if resolvedMount.isEmpty && hw.found && !bsdName.isEmpty {
            if let m = provider.findMountPoint(forBsdName: bsdName) {
                resolvedMount = m
            }
        }
        var mountToInspect = !resolvedMount.isEmpty ? resolvedMount : (!targetQuery.isEmpty && targetQuery.starts(with: "/") ? targetQuery : "")
        if isAutoDiscovered && resolvedMount.isEmpty {
            mountToInspect = ""
        }
        let hint = disambiguatedDriveKey ?? (bsdName.isEmpty ? (targetMount.isEmpty ? "default" : targetMount) : bsdName)
        let checkSub = shouldCheckSubpaths(cfg: cfg, mountPoint: mountToInspect)

        return PreparedTargetInput(
            targetMount: targetMount,
            targetQuery: targetQuery,
            driveKeyHint: hint,
            disambiguatedDriveKey: disambiguatedDriveKey,
            hardware: hw,
            mountToInspect: mountToInspect,
            isAutoDiscovered: isAutoDiscovered,
            shouldCheckSubpaths: checkSub
        )
    }

    private func collectPhaseATelemetry(
        cfg: DiskHealthConfig,
        provider: any DiskTelemetryProvider,
        forceCanary: Bool,
        isSystemSleeping: Bool,
        nowTs: TimeInterval
    ) -> [PreparedTargetTelemetry] {
        snapshotLock.lock()
        let prevMulti = self.latestMultiSnapshotInternal
        let prevSingle = self.latestSnapshotInternal
        snapshotLock.unlock()

        var inputs: [PreparedTargetInput] = []

        if cfg.monitorAllDisks {
            let all = provider.listAllDevices(maxCount: 32)
            var serialCounts: [String: Int] = [:]
            for dev in all where dev.found && !DiskHealthMonitor.isVirtualDiskMetrics(dev) {
                let ser = cStringToSwift(dev.serialNumber).trimmingCharacters(in: .whitespacesAndNewlines)
                if DiskHealthMonitor.isValidUniqueSerial(ser) {
                    serialCounts[ser, default: 0] += 1
                }
            }

            var seenKeys = Set<String>()
            var enumeratedDevices: [(dev: DiskHardwareMetrics, key: String)] = []
            enumeratedDevices.reserveCapacity(all.count)
            for dev in all where dev.found && !DiskHealthMonitor.isVirtualDiskMetrics(dev) {
                let ser = cStringToSwift(dev.serialNumber).trimmingCharacters(in: .whitespacesAndNewlines)
                let bsd = cStringToSwift(dev.bsdName).trimmingCharacters(in: .whitespacesAndNewlines)
                let key: String
                if DiskHealthMonitor.isValidUniqueSerial(ser) && (serialCounts[ser] ?? 0) == 1 {
                    key = ser
                } else if !ser.isEmpty && !bsd.isEmpty {
                    key = "\(ser)#\(bsd)"
                } else {
                    key = bsd
                }
                if key.isEmpty || !seenKeys.contains(key) {
                    if !key.isEmpty { seenKeys.insert(key) }
                    enumeratedDevices.append((dev, key))
                }
            }

            if !enumeratedDevices.isEmpty {
                for (dev, key) in enumeratedDevices {
                    let bsd = cStringToSwift(dev.bsdName)
                    inputs.append(prepareInput(
                        targetMount: "",
                        targetQuery: bsd,
                        disambiguatedDriveKey: key,
                        preloadedHardware: dev,
                        isAutoDiscovered: true,
                        cfg: cfg,
                        provider: provider,
                        prevMulti: prevMulti,
                        prevSingle: prevSingle,
                        nowTs: nowTs
                    ))
                }
            } else {
                inputs.append(prepareInput(
                    targetMount: cfg.targetVolumePath ?? "",
                    targetQuery: cfg.targetDeviceQuery ?? "",
                    disambiguatedDriveKey: nil,
                    preloadedHardware: nil,
                    isAutoDiscovered: false,
                    cfg: cfg,
                    provider: provider,
                    prevMulti: prevMulti,
                    prevSingle: prevSingle,
                    nowTs: nowTs
                ))
            }
        } else if !cfg.monitoredTargets.isEmpty {
            for target in cfg.monitoredTargets {
                let isMount = target.hasPrefix("/")
                inputs.append(prepareInput(
                    targetMount: isMount ? target : "",
                    targetQuery: isMount ? "" : target,
                    disambiguatedDriveKey: nil,
                    preloadedHardware: nil,
                    isAutoDiscovered: false,
                    cfg: cfg,
                    provider: provider,
                    prevMulti: prevMulti,
                    prevSingle: prevSingle,
                    nowTs: nowTs
                ))
            }
        } else {
            inputs.append(prepareInput(
                targetMount: cfg.targetVolumePath ?? "",
                targetQuery: cfg.targetDeviceQuery ?? "",
                disambiguatedDriveKey: nil,
                preloadedHardware: nil,
                isAutoDiscovered: false,
                cfg: cfg,
                provider: provider,
                prevMulti: prevMulti,
                prevSingle: prevSingle,
                nowTs: nowTs
            ))
        }

        if inputs.isEmpty {
            inputs.append(prepareInput(
                targetMount: cfg.targetVolumePath ?? "",
                targetQuery: cfg.targetDeviceQuery ?? "",
                disambiguatedDriveKey: nil,
                preloadedHardware: nil,
                isAutoDiscovered: false,
                cfg: cfg,
                provider: provider,
                prevMulti: prevMulti,
                prevSingle: prevSingle,
                nowTs: nowTs
            ))
        }

        let batchTargets: [DriveProbeTarget] = inputs.compactMap { inp in
            guard !inp.mountToInspect.isEmpty else { return nil }
            return DriveProbeTarget(
                driveKey: inp.driveKeyHint,
                mountPath: inp.mountToInspect,
                isInternal: inp.hardware.isInternal,
                runCanary: cfg.enableActiveCanary,
                requiredSubpaths: inp.shouldCheckSubpaths ? cfg.requiredSubpaths : [],
                inspectApfs: true
            )
        }

        let probeResults = ParallelDriveProber.shared.probeAll(
            targets: batchTargets,
            forceCanary: forceCanary,
            isSystemSleeping: isSystemSleeping,
            nowTs: nowTs,
            timeoutSeconds: 3.0,
            telemetry: provider
        )

        return inputs.map { inp in
            let probe = probeResults[inp.driveKeyHint]
            let isQuarantined = probe?.isQuarantined ?? (!inp.mountToInspect.isEmpty && ParallelDriveProber.shared.isMountQuarantined(inp.mountToInspect))

            let fsMetrics: FilesystemMountMetrics
            if isQuarantined {
                let totalB = probe?.fsMetrics.totalBytes ?? 0
                fsMetrics = FilesystemMountMetrics(
                    isMounted: true,
                    mountPoint: inp.mountToInspect,
                    filesystemType: "quarantined",
                    isReadOnly: false,
                    totalBytes: totalB,
                    freeBytes: 0,
                    purgeableBytes: 0,
                    usedBytes: totalB,
                    usedPercent: 0.0
                )
            } else if let probedFs = probe?.fsMetrics {
                fsMetrics = probedFs
            } else {
                fsMetrics = provider.inspectFilesystem(mountPath: inp.mountToInspect)
            }

            let effectiveMount = (inp.isAutoDiscovered && !fsMetrics.isMounted) ? "" : inp.mountToInspect
            let checkSub = shouldCheckSubpaths(cfg: cfg, mountPoint: effectiveMount)
            let subpathsStatus: [String: Bool]
            if !checkSub {
                subpathsStatus = [:]
            } else if let probedSub = probe?.subpathsStatus, !probedSub.isEmpty || cfg.requiredSubpaths.isEmpty {
                subpathsStatus = probedSub
            } else {
                subpathsStatus = provider.checkSubpaths(
                    mountPoint: fsMetrics.mountPoint,
                    isMounted: fsMetrics.isMounted,
                    requiredSubpaths: cfg.requiredSubpaths
                )
            }

            let apfsContainer: ApfsContainerFleetMetrics?
            if let probedApfs = probe?.apfsContainer {
                apfsContainer = probedApfs
            } else if !isQuarantined && fsMetrics.isMounted && fsMetrics.filesystemType.lowercased() == "apfs" {
                apfsContainer = provider.inspectApfsContainer(mountPath: fsMetrics.mountPoint)
            } else {
                apfsContainer = nil
            }

            var canaryOk = false
            var canaryLatencyMs = 0.0
            var canaryError = fsMetrics.isMounted ? "Canary disabled" : "Volume not mounted"
            if isQuarantined {
                canaryOk = false
                canaryLatencyMs = 3000.0
                canaryError = probe?.canaryResult?.error ?? "CONTROLLER_UNRESPONSIVE_CIRCUIT_OPEN"
            } else if fsMetrics.isMounted && cfg.enableActiveCanary {
                if isSystemSleeping {
                    canaryOk = true
                    canaryError = "Suppressed while system is sleeping"
                } else {
                    let res = probe?.canaryResult ?? provider.runCanaryProbe(targetMount: fsMetrics.mountPoint, force: forceCanary, nowTs: nowTs)
                    canaryOk = res.ok
                    canaryLatencyMs = res.latencyMs
                    canaryError = res.error
                    if !canaryOk && inp.isAutoDiscovered {
                        let postCheck = provider.inspectFilesystem(mountPath: fsMetrics.mountPoint)
                        if !postCheck.isMounted {
                            canaryOk = true
                            canaryError = "Volume unmounted during probe"
                        }
                    }
                }
            }

            return PreparedTargetTelemetry(
                targetMount: inp.targetMount,
                targetQuery: inp.targetQuery,
                disambiguatedDriveKey: inp.disambiguatedDriveKey,
                hardware: inp.hardware,
                mountToInspect: effectiveMount,
                isAutoDiscovered: inp.isAutoDiscovered,
                fsMetrics: fsMetrics,
                subpathsStatus: subpathsStatus,
                apfsContainer: apfsContainer,
                canaryOk: canaryOk,
                canaryLatencyMs: canaryLatencyMs,
                canaryError: canaryError,
                isQuarantined: isQuarantined
            )
        }
    }

    // MARK: - Phase B In-Memory Evaluation Under engineLock

    private func evaluatePreparedTargetLocked(
        prepared: PreparedTargetTelemetry,
        allowNotifications: Bool,
        nowTs: TimeInterval,
        formattedTime: String,
        formattedShortTime: String,
        cfg: DiskHealthConfig,
        provider: any DiskTelemetryProvider
    ) -> DiskHealthSnapshot {
        let hw = prepared.hardware
        let vendorName = hw.found ? cStringToSwift(hw.vendorName) : "Generic"
        let productName = hw.found ? cStringToSwift(hw.productName) : "Storage Device"
        let productRevision = hw.found ? cStringToSwift(hw.productRevision) : ""
        let bsdName = hw.found ? cStringToSwift(hw.bsdName) : ""
        let serialNumber = hw.found ? cStringToSwift(hw.serialNumber) : ""
        let interconnect = hw.found ? cStringToSwift(hw.interconnectType) : "Storage"
        let protocolType = hw.found ? cStringToSwift(hw.protocolType) : ""
        let linkSpeedFormatted = formatLinkSpeed(hw.linkSpeedBps, interconnect: interconnect)
        let fsMetrics = prepared.fsMetrics

        let driveKey: String = {
            if let disambiguated = prepared.disambiguatedDriveKey, !disambiguated.isEmpty {
                return disambiguated
            }
            if !serialNumber.isEmpty && !DiskHealthSnapshot.isPlaceholderSerial(serialNumber) {
                return serialNumber
            }
            if !serialNumber.isEmpty && !bsdName.isEmpty {
                return "\(serialNumber)#\(bsdName)"
            }
            if !bsdName.isEmpty { return bsdName }
            if !prepared.mountToInspect.isEmpty { return prepared.mountToInspect }
            if !prepared.targetQuery.isEmpty { return prepared.targetQuery }
            return "default"
        }()

        // Throughput & Latency Calculations (tracked per driveKey)
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

        var driveState = state.getDriveState(key: driveKey, bsdName: bsdName, serial: serialNumber)
        PersistentStateStore.synchronizeBaselines(driveState: &driveState, hardware: hw, filesystem: fsMetrics)
        state.drives[driveKey] = driveState

        let inWakeGrace = isSystemSleeping || (lastWakeTime > 0 && (nowTs - lastWakeTime < 8.0))
        let evaluationContext = HealthEvaluationContext(
            nowTs: nowTs,
            config: cfg,
            hardware: hw,
            linkSpeedFormatted: linkSpeedFormatted,
            interconnect: interconnect,
            mountToInspect: prepared.mountToInspect,
            filesystem: fsMetrics,
            subpathsStatus: prepared.subpathsStatus,
            canaryOk: prepared.canaryOk,
            canaryLatencyMs: prepared.canaryLatencyMs,
            canaryError: prepared.canaryError,
            avgReadLatMs: avgReadLatMs,
            avgWriteLatMs: avgWriteLatMs,
            inWakeGrace: inWakeGrace,
            hostThermalState: provider.currentHostThermalState(),
            driveState: driveState,
            recentTemperatureSamples: recentTemperatureSamples[driveKey] ?? [],
            apfsContainer: prepared.apfsContainer,
            isControllerUnresponsive: prepared.isQuarantined
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
        let tempC = Int(hw.temperatureCelsius)

        var finalSnapshot = DiskHealthSnapshot(
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
            subpathsStatus: prepared.subpathsStatus,
            canaryOk: prepared.canaryOk,
            canaryLatencyMs: prepared.canaryLatencyMs,
            canaryError: prepared.canaryError,
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
            lastVerifyOk: driveState.lastVerifyOk,
            customDriveKey: prepared.disambiguatedDriveKey,
            usbCurrentAvailableMa: hw.usbCurrentAvailableMa,
            usbCurrentRequiredMa: hw.usbCurrentRequiredMa,
            linkWidthLanes: hw.linkWidthLanes,
            smartSourceType: hw.smartSourceType,
            isControllerUnresponsive: prepared.isQuarantined,
            busErrorCount: hw.busErrorCount,
            busResetCount: hw.busResetCount,
            damagedExtents: SurfaceScannerService.shared.damagedExtents(forMount: fsMetrics.mountPoint),
            apfsContainer: prepared.apfsContainer
        )

        let rolling = TelemetryHistoryStore.shared.computeRollingForecasts(for: finalSnapshot)
        finalSnapshot.rolling7dTerabytesWrittenPerDay = rolling.rolling7dTBPerDay
        finalSnapshot.rolling30dTerabytesWrittenPerDay = rolling.rolling30dTBPerDay
        finalSnapshot.p95WriteLatencyMs = rolling.p95WriteLatencyMs
        finalSnapshot.p95TemperatureCelsius = rolling.p95TempCelsius

        if let disambiguated = prepared.disambiguatedDriveKey, !disambiguated.isEmpty, disambiguated != finalSnapshot.serialNumber {
            finalSnapshot.customDriveKey = disambiguated
        }

        if allowNotifications {
            AlertCoordinator.shared.processAlertsAndDigestLocked(
                snapshot: finalSnapshot,
                rawMetrics: hw,
                driveKey: driveKey,
                state: &self.state,
                config: cfg
            ) { [weak self] updatedLog in
                if Thread.isMainThread {
                    self?.publishedActionLog = updatedLog
                } else {
                    DispatchQueue.main.async { [weak self] in
                        self?.publishedActionLog = updatedLog
                    }
                }
            }
        }

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

        return finalSnapshot
    }

    static func isValidUniqueSerial(_ s: String) -> Bool {
        return !DiskHealthSnapshot.isPlaceholderSerial(s)
    }

    static func isVirtualDiskMetrics(_ dev: DiskHardwareMetrics) -> Bool {
        let interconnect = cStringToSwift(dev.interconnectType).lowercased()
        let product = cStringToSwift(dev.productName).lowercased()
        let vendor = cStringToSwift(dev.vendorName).lowercased()
        if interconnect.contains("virtual") || interconnect.contains("file") {
            return true
        }
        if product.contains("disk image") || vendor.contains("disk image") {
            return true
        }
        return false
    }

    /// Evaluates health, performance, and SMART telemetry across all monitored physical storage devices.
    /// Phase A collects IOKit/VFS/canary telemetry without holding `engineLock`; Phase B evaluates
    /// pure rules and updates persistent state atomically under `engineLock`.
    @discardableResult
    func evaluateAllMonitoredDisks(
        forceCanary: Bool = false,
        allowNotifications: Bool = true,
        persistState: Bool = true,
        telemetryProvider: (any DiskTelemetryProvider)? = nil
    ) -> MultiDiskHealthSnapshot {
        let provider = telemetryProvider ?? self.defaultTelemetryProvider
        let now = Date()
        let nowTs = now.timeIntervalSince1970
        let formattedTime = isoTimestampFormatter.string(from: now)
        let formattedShortTime = shortTimeFormatter.string(from: now)
        let cfg = ConfigManager.shared.currentConfig

        engineLock.lock()
        let sleepingAtStart = self.isSystemSleeping
        engineLock.unlock()

        // Phase A: Concurrent Unlocked Telemetry Acquisition
        let preparedTargets = collectPhaseATelemetry(
            cfg: cfg,
            provider: provider,
            forceCanary: forceCanary,
            isSystemSleeping: sleepingAtStart,
            nowTs: nowTs
        )

        // Phase B: Synchronized Delta, Rule, State & Alert Evaluation
        engineLock.lock()
        let snapshots = preparedTargets.map { prepared in
            evaluatePreparedTargetLocked(
                prepared: prepared,
                allowNotifications: allowNotifications,
                nowTs: nowTs,
                formattedTime: formattedTime,
                formattedShortTime: formattedShortTime,
                cfg: cfg,
                provider: provider
            )
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

        snapshotLock.lock()
        self.latestMultiSnapshotInternal = multi
        self.state.lastOverallSeverity = worstSeverity.rawValue

        if selectedDashboardDriveKeyInternal.isEmpty || !snapshots.contains(where: { $0.driveKey == selectedDashboardDriveKeyInternal }) {
            selectedDashboardDriveKeyInternal = multi.primarySnapshot?.driveKey ?? snapshots.first?.driveKey ?? ""
        }
        let resolvedSelectedKey = selectedDashboardDriveKeyInternal
        let primary = snapshots.first(where: { $0.driveKey == resolvedSelectedKey }) ?? multi.primarySnapshot ?? snapshots[0]
        self.latestSnapshotInternal = primary
        snapshotLock.unlock()

        if persistState {
            for snap in snapshots {
                _ = TelemetryHistoryStore.shared.recordSnapshot(snap, persistToDisk: true)
            }
            PersistentStateStore.saveLatestStatus(multi: multi, primary: primary)
            saveStateLocked()
        }
        engineLock.unlock()

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
        return self.currentSnapshot ?? multi.primarySnapshot ?? multi.disks[0]
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
        let multi = self.currentMultiSnapshot
        let snap: DiskHealthSnapshot
        if let overrideKey = driveKeyOverride, let found = multi?.disks.first(where: { $0.driveKey == overrideKey }) {
            snap = found
        } else {
            snap = self.currentSnapshot ?? self.evaluateHealth(forceCanary: false, allowNotifications: false)
        }
        let snapMount = snap.mountPoint
        let cfgVol = ConfigManager.shared.currentConfig.targetVolumePath ?? ""
        let target = targetMountOverride ?? (!snapMount.isEmpty ? snapMount : (!cfgVol.isEmpty ? cfgVol : (!snap.bsdName.isEmpty ? "/dev/\(snap.bsdName)" : "/")))
        let capturedDriveKey = driveKeyOverride ?? snap.driveKey
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

            let updatedSnap: DiskHealthSnapshot
            if ConfigManager.shared.currentConfig.monitorAllDisks || !ConfigManager.shared.currentConfig.monitoredTargets.isEmpty {
                let fleet = self.evaluateAllMonitoredDisks(forceCanary: true, allowNotifications: !ok)
                updatedSnap = fleet.disks.first(where: { $0.driveKey == capturedDriveKey }) ?? fleet.primarySnapshot ?? self.currentSnapshot ?? self.evaluateHealth(forceCanary: false, allowNotifications: false)
            } else {
                updatedSnap = self.evaluateHealth(forceCanary: true, allowNotifications: !ok)
            }
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

    // MARK: - Alert Coordinator Forwarding & Automation Simulation

    func waitForPendingNotifications(timeout: TimeInterval = 16.0) {
        AlertCoordinator.shared.waitForPendingNotifications(timeout: timeout)
    }

    static func makeRuleScriptEnvironment(snapshot: DiskHealthSnapshot, rule: ActionRule, triggerReason: String) -> [String: String] {
        AlertCoordinator.makeRuleScriptEnvironment(snapshot: snapshot, rule: rule, triggerReason: triggerReason)
    }

    /// Simulates or live-executes an `ActionRule` against either a provided snapshot or a synthetic matching snapshot,
    /// recording the result in the persistent audit log.
    @discardableResult
    func simulateActionRule(
        _ rule: ActionRule,
        on snapshotOverride: DiskHealthSnapshot? = nil,
        executeLive: Bool = false,
        persistAuditRecord: Bool = true
    ) -> ActionExecutionRecord {
        let baseSnap = snapshotOverride ?? self.currentSnapshot
        let (simSnap, prevSev, simRates) = ActionRuleEngine.makeSyntheticMatchingSnapshot(for: rule, baseSnapshot: baseSnap)
        let targetSnap = snapshotOverride ?? simSnap
        let (_, reason) = ActionRuleEngine.evaluateRuleCondition(
            rule: rule,
            snapshot: targetSnap,
            previousSeverity: prevSev,
            historyRates: simRates,
            isSleepNotificationEvent: (rule.triggerMetric == .systemWillSleep)
        )

        let record = ActionRuleEngine.shared.executeRuleAction(
            rule: rule,
            snapshot: targetSnap,
            triggerReason: reason,
            nowTs: Date().timeIntervalSince1970,
            dryRun: !executeLive || rule.dryRunOnly
        )

        if persistAuditRecord {
            engineLock.lock()
            ActionRuleEngine.shared.appendAuditRecord(record, to: &self.state)
            let updatedLog = self.state.recentActionExecutions
            saveStateLocked()
            engineLock.unlock()

            if Thread.isMainThread {
                self.publishedActionLog = updatedLog
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.publishedActionLog = updatedLog
                }
            }
        }
        return record
    }

    /// Clears the rule execution audit log in `state.json`.
    func clearActionAuditLog() {
        engineLock.lock()
        self.state.recentActionExecutions.removeAll()
        saveStateLocked(force: true)
        engineLock.unlock()
        if Thread.isMainThread {
            self.publishedActionLog = []
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.publishedActionLog = []
            }
        }
    }

    func testAlertScriptResult(timeoutSec: TimeInterval = 15.0) -> Result<String, DiskHealthError> {
        let snap = self.currentSnapshot ?? self.evaluateHealth(forceCanary: false, allowNotifications: false, persistState: false)
        return AlertCoordinator.shared.testAlertScriptResult(snapshot: snap, timeoutSec: timeoutSec)
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

    // MARK: - Surface Read Scan Delegation

    func runSurfaceReadScan(
        targetMount: String? = nil,
        mode: SurfaceScanMode = .quick,
        maxBytesToScan: UInt64? = nil,
        cancellationToken: SurfaceScanCancellationToken? = nil,
        progressHandler: ((SurfaceScanProgress) -> Void)? = nil
    ) -> (ok: Bool, filesScanned: Int, bytesScanned: UInt64, readErrors: Int, elapsedMs: Double, summary: String) {
        let provider = self.defaultTelemetryProvider
        let targetPath: String = {
            if let explicit = targetMount, !explicit.isEmpty { return explicit }
            if let cfgTarget = ConfigManager.shared.currentConfig.targetVolumePath, !cfgTarget.isEmpty { return cfgTarget }
            if let snap = self.currentSnapshot, snap.isMounted, !snap.mountPoint.isEmpty, !snap.isControllerUnresponsive {
                return snap.mountPoint
            }
            if let multi = self.currentMultiSnapshot {
                if let healthyInternal = multi.disks.first(where: { $0.isInternal && $0.isMounted && !$0.isControllerUnresponsive }) {
                    return healthyInternal.mountPoint
                }
                if let healthyAny = multi.disks.first(where: { $0.isMounted && !$0.isControllerUnresponsive }) {
                    return healthyAny.mountPoint
                }
            }
            return "/"
        }()

        if ParallelDriveProber.shared.isMountQuarantined(targetPath) {
            return (false, 0, 0, 1, 0.0, "Surface scan aborted: Target volume '\(targetPath)' is quarantined due to unresponsive storage controller.")
        }

        let fsMetrics = provider.inspectFilesystem(mountPath: targetPath)
        guard fsMetrics.isMounted, !fsMetrics.mountPoint.isEmpty else {
            return (false, 0, 0, 1, 0.0, "Surface scan aborted: Target volume '\(targetPath)' is not mounted.")
        }

        let res = SurfaceScannerService.shared.runSurfaceReadScan(
            mountPoint: fsMetrics.mountPoint,
            totalBytes: fsMetrics.totalBytes,
            freeBytes: fsMetrics.freeBytes,
            mode: mode,
            maxBytesToScan: maxBytesToScan,
            cancellationToken: cancellationToken,
            progressHandler: progressHandler
        )
        if res.readErrors > 0 || !SurfaceScannerService.shared.damagedExtents(forMount: fsMetrics.mountPoint).isEmpty {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                _ = self?.evaluateAllMonitoredDisks(forceCanary: false, allowNotifications: false, persistState: false)
            }
        }
        return res
    }
}
