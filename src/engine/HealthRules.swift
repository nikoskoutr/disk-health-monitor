// ============================================================================
// File: HealthRules.swift
// Module: Layer 3 (Telemetry & Domain Engine)
// Purpose: Pure functional domain health rules evaluating storage reliability,
//          SMART metrics, thermal boundaries, driver latency, and canary I/O.
// Concurrency: Thread-safe, side-effect-free Sendable value types.
// ============================================================================

import Foundation

// MARK: - Health Evaluation Context & Outcome

/// Immutable snapshot of telemetry and environmental context passed to each HealthRule.
struct HealthEvaluationContext: Sendable {
    let nowTs: TimeInterval
    let config: DiskHealthConfig
    let hardware: DiskHardwareMetrics
    let linkSpeedFormatted: String
    let interconnect: String
    let mountToInspect: String
    let filesystem: FilesystemMountMetrics
    let subpathsStatus: [String: Bool]
    let canaryOk: Bool
    let canaryLatencyMs: Double
    let canaryError: String
    let avgReadLatMs: Double
    let avgWriteLatMs: Double
    let inWakeGrace: Bool
    let hostThermalState: ProcessInfo.ThermalState
    var driveState: DriveBaselineState
    var recentTemperatureSamples: [(timestamp: TimeInterval, tempC: Int)]
    var apfsContainer: ApfsContainerFleetMetrics? = nil
}

struct HealthRuleOutcome: Sendable {
    var issues: [HealthIssue] = []
    var scorePenalty: Int = 0
    var updatedTemperatureSamples: [(timestamp: TimeInterval, tempC: Int)]? = nil
    var healVerifyFailureToSkipped: Bool = false
    var logMessages: [String] = []
}

protocol HealthRule: Sendable {
    var ruleId: String { get }
    func evaluate(context: HealthEvaluationContext) -> HealthRuleOutcome
}

// MARK: - Rule 1: Hardware Presence

struct HardwarePresenceRule: HealthRule {
    let ruleId = "HardwarePresence"

    func evaluate(context: HealthEvaluationContext) -> HealthRuleOutcome {
        var outcome = HealthRuleOutcome()
        guard !context.hardware.found else { return outcome }

        if context.inWakeGrace {
            outcome.logMessages.append("Hardware presence not confirmed during wake grace period (8s); suppressing false alert.")
        } else {
            outcome.issues.append(HealthIssue(
                code: "HW_DISCONNECTED",
                severity: .critical,
                title: "Storage Hardware Disconnected",
                detail: "Target device was not detected on macOS IOKit storage buses."
            ))
            outcome.scorePenalty = 60
        }
        return outcome
    }
}

// MARK: - Rule 2: Volume Mount & Read-Only

struct VolumeMountAndReadOnlyRule: HealthRule {
    let ruleId = "VolumeMountAndReadOnly"

    static let naturallyReadOnlyFsTypes: Set<String> = [
        "ntfs", "cd9660", "udf", "iso9660", "cdda", "webdav", "devfs", "autofs"
    ]

    func evaluate(context: HealthEvaluationContext) -> HealthRuleOutcome {
        var outcome = HealthRuleOutcome()

        if !context.mountToInspect.isEmpty && !context.filesystem.isMounted {
            if context.inWakeGrace {
                outcome.logMessages.append("Volume unmounted status during wake grace period (8s); suppressing false alert.")
            } else {
                outcome.issues.append(HealthIssue(
                    code: "VOLUME_UNMOUNTED",
                    severity: .critical,
                    title: "Volume Unmounted",
                    detail: "Volume \(context.mountToInspect) is not mounted."
                ))
                outcome.scorePenalty += 50
            }
        } else if context.filesystem.isMounted {
            // Read-Only Mount (excluding sealed macOS root filesystem "/")
            if context.filesystem.isReadOnly && context.filesystem.mountPoint != "/" {
                let fsType = context.filesystem.filesystemType.lowercased()
                let isNaturallyReadOnly = Self.naturallyReadOnlyFsTypes.contains(fsType)
                if !isNaturallyReadOnly {
                    let shouldFlag: Bool
                    if !context.hardware.isInternal && context.driveState.wasWritable == nil {
                        shouldFlag = (fsType == "apfs" || fsType == "hfs" || fsType == "exfat" || fsType == "msdos")
                    } else {
                        shouldFlag = true
                    }

                    if shouldFlag {
                        outcome.issues.append(HealthIssue(
                            code: "VOLUME_READONLY",
                            severity: .critical,
                            title: "Volume Mounted Read-Only",
                            detail: "Volume \(context.filesystem.mountPoint) is mounted in read-only mode (filesystem journal fault or protection)."
                        ))
                        outcome.scorePenalty += 45
                    }
                }
            }
        }
        return outcome
    }
}

// MARK: - Rule 3: Required Subpaths

struct RequiredSubpathsRule: HealthRule {
    let ruleId = "RequiredSubpaths"

    func evaluate(context: HealthEvaluationContext) -> HealthRuleOutcome {
        var outcome = HealthRuleOutcome()
        guard context.filesystem.isMounted else { return outcome }

        for (subpath, exists) in context.subpathsStatus {
            if !exists {
                outcome.issues.append(HealthIssue(
                    code: "REQUIRED_PATH_MISSING",
                    severity: .critical,
                    title: "Required Subpath Inaccessible",
                    detail: "Configured path '\(subpath)' on \(context.filesystem.mountPoint) could not be accessed."
                ))
                outcome.scorePenalty += 35
            }
        }
        return outcome
    }
}

// MARK: - Rule 4: Active Canary Probe

struct CanaryProbeRule: HealthRule {
    let ruleId = "CanaryProbe"

    func evaluate(context: HealthEvaluationContext) -> HealthRuleOutcome {
        var outcome = HealthRuleOutcome()
        guard context.filesystem.isMounted && context.config.enableActiveCanary else { return outcome }

        if context.inWakeGrace {
            outcome.logMessages.append("Canary probe issue suppressed during wake grace period (8s).")
        } else if !context.canaryOk {
            if context.canaryError.contains("CIRCUIT_OPEN") || context.canaryError.contains("TIMEOUT") {
                outcome.issues.append(HealthIssue(
                    code: "IO_CONTROLLER_UNRESPONSIVE",
                    severity: .critical,
                    title: "I/O Controller Unresponsive",
                    detail: "Storage controller on \(context.filesystem.mountPoint) timed out after 3000ms. Quarantined."
                ))
                outcome.scorePenalty += 55
            } else {
                outcome.issues.append(HealthIssue(
                    code: "CANARY_IO_FAILED",
                    severity: .critical,
                    title: "Filesystem Canary Probe Failed",
                    detail: "Canary write/sync/read probe on \(context.filesystem.mountPoint) failed: \(context.canaryError)"
                ))
                outcome.scorePenalty += 40
            }
        } else if context.canaryLatencyMs > 300.0 {
            outcome.issues.append(HealthIssue(
                code: "CANARY_HIGH_LATENCY",
                severity: .warning,
                title: "High Filesystem Latency",
                detail: String(format: "Canary probe took %.1f ms (> 300 ms).", context.canaryLatencyMs)
            ))
            outcome.scorePenalty += 10
        }
        return outcome
    }
}

// MARK: - Rule 5: Free Space

struct DiskSpaceRule: HealthRule {
    let ruleId = "DiskSpace"

    func evaluate(context: HealthEvaluationContext) -> HealthRuleOutcome {
        var outcome = HealthRuleOutcome()
        guard context.filesystem.isMounted else { return outcome }

        let freeGB = Double(context.filesystem.freeBytes) / 1_000_000_000.0
        let totalGB = Double(context.filesystem.totalBytes) / 1_000_000_000.0
        let cfg = context.config
        let effectiveCriticalGB = totalGB > 0 ? min(cfg.minFreeSpaceCriticalGB, totalGB * 0.05) : cfg.minFreeSpaceCriticalGB
        let effectiveWarningGB = totalGB > 0 ? min(cfg.minFreeSpaceWarningGB, totalGB * 0.10) : cfg.minFreeSpaceWarningGB
        let wasUnhealthy = context.driveState.lastOverallSeverity != HealthSeverity.healthy.rawValue
        let effectiveWarnPercent = wasUnhealthy ? max(10.0, cfg.diskUsedWarningPercent - 1.5) : cfg.diskUsedWarningPercent

        if context.filesystem.usedPercent >= cfg.diskUsedCriticalPercent || freeGB < effectiveCriticalGB {
            outcome.issues.append(HealthIssue(
                code: "DISK_SPACE_CRITICAL",
                severity: .critical,
                title: "Critically Low Disk Space",
                detail: String(format: "Only %.1f GB free (%.1f%% used on %@).", freeGB, context.filesystem.usedPercent, context.filesystem.mountPoint)
            ))
            outcome.scorePenalty += 25
        } else if context.filesystem.usedPercent >= effectiveWarnPercent || freeGB < effectiveWarningGB {
            outcome.issues.append(HealthIssue(
                code: "DISK_SPACE_WARNING",
                severity: .warning,
                title: "Low Disk Space Warning",
                detail: String(format: "%.1f GB free (%.1f%% used on %@).", freeGB, context.filesystem.usedPercent, context.filesystem.mountPoint)
            ))
            outcome.scorePenalty += 10
        }
        return outcome
    }
}

// MARK: - Rule 6: USB Link Speed

struct UsbLinkSpeedRule: HealthRule {
    let ruleId = "UsbLinkSpeed"

    func evaluate(context: HealthEvaluationContext) -> HealthRuleOutcome {
        var outcome = HealthRuleOutcome()
        let cfg = context.config
        let hw = context.hardware

        let isUsbOrThunderbolt = context.interconnect.lowercased().contains("usb") || context.interconnect.lowercased().contains("thunderbolt")
        if hw.found && isUsbOrThunderbolt && cfg.minExpectedUsbSpeedBps > 0 && hw.linkSpeedBps > 0 && hw.linkSpeedBps < cfg.minExpectedUsbSpeedBps {
            outcome.issues.append(HealthIssue(
                code: "USB_LINK_DEGRADED",
                severity: .warning,
                title: "Link Speed Degraded",
                detail: "Drive negotiated at \(context.linkSpeedFormatted) instead of expected \(formatLinkSpeed(cfg.minExpectedUsbSpeedBps, interconnect: context.interconnect)). Check cable or port."
            ))
            outcome.scorePenalty += 15
        }
        return outcome
    }
}

// MARK: - Rule 7: NVMe Critical Warning Byte

struct NVMeCriticalWarningRule: HealthRule {
    let ruleId = "NVMeCriticalWarning"

    func evaluate(context: HealthEvaluationContext) -> HealthRuleOutcome {
        var outcome = HealthRuleOutcome()
        guard context.hardware.smartValid else { return outcome }

        if context.hardware.criticalWarning != 0 {
            outcome.issues.append(HealthIssue(
                code: "SMART_CRITICAL_WARNING",
                severity: .critical,
                title: "NVMe S.M.A.R.T. Critical Warning",
                detail: String(format: "NVMe controller reported CRITICAL_WARNING = 0x%02X.", context.hardware.criticalWarning)
            ))
            outcome.scorePenalty += 50
        }
        return outcome
    }
}

// MARK: - Rule 8: Temperature & Thermal Spike

struct ThermalAndSpikeRule: HealthRule {
    let ruleId = "ThermalAndSpike"

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

    func evaluate(context: HealthEvaluationContext) -> HealthRuleOutcome {
        var outcome = HealthRuleOutcome()
        guard context.hardware.smartValid else { return outcome }

        let tempC = Int(context.hardware.temperatureCelsius)
        let cfg = context.config
        let wasUnhealthy = context.driveState.lastOverallSeverity != HealthSeverity.healthy.rawValue
        let effectiveWarnTemp = wasUnhealthy ? (cfg.tempWarningCelsius - 2) : cfg.tempWarningCelsius

        if tempC >= cfg.tempCriticalCelsius {
            outcome.issues.append(HealthIssue(
                code: "TEMP_CRITICAL",
                severity: .critical,
                title: "Drive Overheating (Critical)",
                detail: "Temperature is \(tempC)°C (>= \(cfg.tempCriticalCelsius)°C thermal damage threshold)."
            ))
            outcome.scorePenalty += 35
        } else if tempC >= effectiveWarnTemp {
            outcome.issues.append(HealthIssue(
                code: "TEMP_WARNING",
                severity: .warning,
                title: "Elevated Drive Temperature",
                detail: "Temperature is \(tempC)°C (>= \(cfg.tempWarningCelsius)°C warning threshold)."
            ))
            outcome.scorePenalty += 15
        }

        if !context.inWakeGrace && tempC > 0 {
            let (updatedSamples, spikeIssue, spikePenalty) = ThermalAndSpikeRule.evaluateThermalSpike(
                samples: context.recentTemperatureSamples,
                currentTempC: tempC,
                nowTs: context.nowTs
            )
            outcome.updatedTemperatureSamples = updatedSamples
            if let spikeIssue = spikeIssue {
                outcome.issues.append(spikeIssue)
                outcome.scorePenalty += spikePenalty
            }
        }
        return outcome
    }
}

// MARK: - Rule 9: Endurance & Available Spare

struct EnduranceAndSpareRule: HealthRule {
    let ruleId = "EnduranceAndSpare"

    func evaluate(context: HealthEvaluationContext) -> HealthRuleOutcome {
        var outcome = HealthRuleOutcome()
        guard context.hardware.smartValid else { return outcome }

        let hw = context.hardware
        let spareThresh = Int(hw.availableSpareThreshold)
        let isSpareDepleted = (spareThresh <= 50 && hw.availableSpare <= hw.availableSpareThreshold) || hw.availableSpare < 10

        if isSpareDepleted {
            outcome.issues.append(HealthIssue(
                code: "SPARE_CRITICAL",
                severity: .critical,
                title: "Available Spare Blocks Depleted",
                detail: "Available spare (\(hw.availableSpare)%) is at or below threshold (\(hw.availableSpareThreshold)%)."
            ))
            outcome.scorePenalty += 40
        } else if hw.availableSpare < 25 {
            outcome.issues.append(HealthIssue(
                code: "SPARE_WARNING",
                severity: .warning,
                title: "Available Spare Blocks Low",
                detail: "Available spare blocks dropped to \(hw.availableSpare)%."
            ))
            outcome.scorePenalty += 15
        }

        if hw.percentageUsed >= 95 {
            outcome.issues.append(HealthIssue(
                code: "WEAR_CRITICAL",
                severity: .critical,
                title: "SSD Lifespan Critical",
                detail: "Percentage Used is \(hw.percentageUsed)% (only \(max(0, 100 - Int(hw.percentageUsed)))% life remaining)."
            ))
            outcome.scorePenalty += 30
        } else if hw.percentageUsed >= 80 {
            outcome.issues.append(HealthIssue(
                code: "WEAR_WARNING",
                severity: .warning,
                title: "SSD Wear Level High",
                detail: "NVMe Percentage Used has reached \(hw.percentageUsed)%."
            ))
            outcome.scorePenalty += 10
        }

        return outcome
    }
}

// MARK: - Rule 10: SMART Integrity & Shutdowns

struct SMARTIntegrityAndShutdownRule: HealthRule {
    let ruleId = "SMARTIntegrityAndShutdown"

    func evaluate(context: HealthEvaluationContext) -> HealthRuleOutcome {
        var outcome = HealthRuleOutcome()
        guard context.hardware.smartValid else { return outcome }

        let hw = context.hardware
        let driveState = context.driveState

        if hw.mediaErrors > (driveState.baselineMediaErrors ?? 0) {
            outcome.issues.append(HealthIssue(
                code: "MEDIA_ERRORS",
                severity: .critical,
                title: "NVMe Media / Data Integrity Errors",
                detail: "Drive reported \(hw.mediaErrors) media/data integrity errors (baseline: \(driveState.baselineMediaErrors ?? 0))."
            ))
            outcome.scorePenalty += 45
        }

        if let baseErr = driveState.baselineErrorLogEntries, hw.errorInfoLogEntries > baseErr {
            let errDelta = hw.errorInfoLogEntries - baseErr
            // Apple Silicon internal ANS2 controllers increment errorInfoLogEntries during routine telemetry
            // even when mediaErrors == 0 and criticalWarning == 0. Require >= 5 delta on healthy internal drives.
            let isHealthyInternal = hw.isInternal && hw.mediaErrors == 0 && hw.criticalWarning == 0
            if !isHealthyInternal || errDelta >= 5 {
                outcome.issues.append(HealthIssue(
                    code: "ERROR_LOG_INCREASED",
                    severity: .warning,
                    title: "NVMe Error Log Entries Increased",
                    detail: "Error log count increased from \(baseErr) to \(hw.errorInfoLogEntries)."
                ))
                outcome.scorePenalty += 15
            }
        }

        if let baseUnsafe = driveState.baselineUnsafeShutdowns, hw.unsafeShutdowns > baseUnsafe {
            let delta = hw.unsafeShutdowns - baseUnsafe
            outcome.issues.append(HealthIssue(
                code: "NEW_UNSAFE_SHUTDOWN",
                severity: .warning,
                title: "Unexpected Disconnect / Unsafe Shutdown",
                detail: "Unsafe shutdown counter increased by +\(delta) (from \(baseUnsafe) to \(hw.unsafeShutdowns))."
            ))
            outcome.scorePenalty += 15
        }

        return outcome
    }
}

// MARK: - Rule 11: Driver Stats & Latency

struct DriverStatsAndLatencyRule: HealthRule {
    let ruleId = "DriverStatsAndLatency"

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

    func evaluate(context: HealthEvaluationContext) -> HealthRuleOutcome {
        var outcome = HealthRuleOutcome()
        guard context.hardware.statsValid else { return outcome }

        let hw = context.hardware
        let driveState = context.driveState

        if hw.errorsRead > (driveState.baselineIoReadErrors ?? 0) || hw.errorsWritten > (driveState.baselineIoWriteErrors ?? 0) {
            outcome.issues.append(HealthIssue(
                code: "IO_DRIVER_ERRORS",
                severity: .critical,
                title: "Storage Driver I/O Errors",
                detail: "macOS driver recorded \(hw.errorsRead) Read errors and \(hw.errorsWritten) Write errors."
            ))
            outcome.scorePenalty += 40
        }

        if hw.retriesRead > (driveState.baselineIoReadRetries ?? 0) || hw.retriesWritten > (driveState.baselineIoWriteRetries ?? 0) {
            outcome.issues.append(HealthIssue(
                code: "IO_DRIVER_RETRIES",
                severity: .warning,
                title: "Storage Driver Retries Detected",
                detail: "macOS driver recorded \(hw.retriesRead) Read retries and \(hw.retriesWritten) Write retries."
            ))
            outcome.scorePenalty += 10
        }

        let (latIssue, latPenalty) = DriverStatsAndLatencyRule.evaluateDriverLatency(
            statsValid: hw.statsValid,
            operationsRead: hw.operationsRead,
            operationsWritten: hw.operationsWritten,
            avgReadLatMs: context.avgReadLatMs,
            avgWriteLatMs: context.avgWriteLatMs
        )
        if let issue = latIssue {
            outcome.issues.append(issue)
            outcome.scorePenalty += latPenalty
        }

        return outcome
    }
}

// MARK: - Rule 12: Host Thermal & Volume Verify Status

struct HostThermalAndVerifyRule: HealthRule {
    let ruleId = "HostThermalAndVerify"

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

    func evaluate(context: HealthEvaluationContext) -> HealthRuleOutcome {
        var outcome = HealthRuleOutcome()

        // Scope host CPU thermal throttling warning to internal system drives so external USB/TB drives
        // are not penalized or alerted across a multi-disk fleet for an internal Mac thermal event.
        if context.hardware.isInternal {
            let (thermalIssue, thermalPenalty) = HostThermalAndVerifyRule.evaluateHostThermal(thermalState: context.hostThermalState)
            if let issue = thermalIssue {
                outcome.issues.append(issue)
                outcome.scorePenalty += thermalPenalty
            }
        }

        if !context.driveState.lastVerifyOk {
            if VolumeVerifierService.isNonCorruptionVerifyFailure(context.driveState.lastVerifyResult) {
                outcome.healVerifyFailureToSkipped = true
            } else {
                outcome.issues.append(HealthIssue(
                    code: "VOLUME_VERIFY_FAILED",
                    severity: .critical,
                    title: "File System Verification Failed",
                    detail: context.driveState.lastVerifyResult
                ))
                outcome.scorePenalty += 40
            }
        }

        return outcome
    }
}

// MARK: - Rule 13: Bus Signal & PHY Integrity (BRIDGE-08)

struct BusSignalIntegrityRule: HealthRule {
    let ruleId = "BusSignalIntegrity"

    func evaluate(context: HealthEvaluationContext) -> HealthRuleOutcome {
        var outcome = HealthRuleOutcome()
        guard context.hardware.found else { return outcome }

        let hw = context.hardware
        let driveState = context.driveState

        let baseErrors = driveState.baselineBusErrors
        let baseResets = driveState.baselineBusResets

        let deltaErrors = (hw.busErrorCount >= baseErrors) ? (hw.busErrorCount - baseErrors) : hw.busErrorCount
        let deltaResets = (hw.busResetCount >= baseResets) ? (hw.busResetCount - baseResets) : hw.busResetCount

        if deltaResets >= 3 {
            outcome.issues.append(HealthIssue(
                code: "BUS_PHY_ERRORS",
                severity: .critical,
                title: "Frequent Storage Bus Resets Detected",
                detail: "Hardware reported \(deltaResets) bus reset(s) (baseline: \(baseResets)). Inspect physical cable, port, or hub power."
            ))
            outcome.scorePenalty += 35
        } else if deltaErrors >= 5 || deltaResets >= 1 {
            outcome.issues.append(HealthIssue(
                code: "BUS_PHY_ERRORS",
                severity: .warning,
                title: "Storage Bus Signal / PHY Errors Detected",
                detail: "Hardware reported +\(deltaErrors) PHY link error(s) and +\(deltaResets) reset(s). Possible cable degradation or loose port."
            ))
            outcome.scorePenalty += 20
        }

        return outcome
    }
}

// MARK: - Rule 14: APFS Swap & Container Space Pressure (APFS-03)

struct ApfsSwapPressureRule: HealthRule {
    let ruleId = "ApfsSwapPressure"

    func evaluate(context: HealthEvaluationContext) -> HealthRuleOutcome {
        var outcome = HealthRuleOutcome()
        guard context.filesystem.isMounted && context.filesystem.filesystemType == "apfs" else { return outcome }

        if let container = context.apfsContainer {
            for vol in container.volumes {
                if vol.role.uppercased() == "VM" {
                    // Check if VM swap volume exceeds 16 GB (17,179,869,184 bytes)
                    let vm16GB: UInt64 = 16 * 1024 * 1024 * 1024
                    if vol.usedBytes >= vm16GB && container.totalCapacityBytes > 0 {
                        let freeRatio = Double(container.freeSpaceBytes) / Double(container.totalCapacityBytes)
                        if freeRatio < 0.10 {
                            outcome.issues.append(HealthIssue(
                                code: "APFS_SWAP_PRESSURE",
                                severity: .warning,
                                title: "APFS Swap Volume Pressure",
                                detail: "VM swap volume has grown to \(ByteCountFormatter.string(fromByteCount: Int64(vol.usedBytes), countStyle: .file)) while shared container free space is under 10%."
                            ))
                            outcome.scorePenalty += 15
                            break
                        }
                    }
                }
            }
        }

        return outcome
    }
}

// MARK: - Standard Health Rule Pipeline

struct StandardHealthRulePipeline: Sendable {
    static let defaultRules: [any HealthRule] = [
        HardwarePresenceRule(),
        VolumeMountAndReadOnlyRule(),
        RequiredSubpathsRule(),
        CanaryProbeRule(),
        DiskSpaceRule(),
        UsbLinkSpeedRule(),
        NVMeCriticalWarningRule(),
        ThermalAndSpikeRule(),
        EnduranceAndSpareRule(),
        SMARTIntegrityAndShutdownRule(),
        DriverStatsAndLatencyRule(),
        HostThermalAndVerifyRule(),
        BusSignalIntegrityRule(),
        ApfsSwapPressureRule()
    ]
}
