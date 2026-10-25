// ============================================================================
// File: ActionRuleEngine.swift
// Module: Layer 3 (Telemetry & Domain Engine)
// Purpose: Declarative "When X Happens, Do Y" automation rule engine with drive
//          scope filtering, poll hysteresis, per-rule cooldowns, safety guards,
//          dry-run simulation, and sandboxed subprocess execution.
// Concurrency: Pure Sendable condition evaluators; execution coordinated via
//              DiskHealthMonitor state persistence and async worker queues.
// ============================================================================

import Foundation
import Darwin

/// Evaluates and executes user-configured `ActionRule` policies against live or simulated telemetry.
final class ActionRuleEngine: @unchecked Sendable {
    static let shared = ActionRuleEngine()

    static let maxAuditHistoryRecords: Int = 50

    /// All 23 canonical issue codes emitted by `StandardHealthRulePipeline` plus severity transitions.
    static let knownIssueCodes: [(code: String, description: String)] = [
        ("TEMP_CRITICAL", "Controller Temperature Critical (>= Crit °C)"),
        ("TEMP_WARNING", "Controller Temperature Warning (>= Warn °C)"),
        ("TEMP_RAPID_RISE", "Rapid Temperature Spike (+8°C in 3 min)"),
        ("MEDIA_ERRORS", "Unrecoverable NVMe Media / Data Integrity Error"),
        ("SMART_CRITICAL_WARNING", "NVMe Critical Warning Register Flag Set"),
        ("SPARE_CRITICAL", "NVMe Available Spare Below Critical Threshold"),
        ("SPARE_WARNING", "NVMe Available Spare Low (< 25%)"),
        ("WEAR_CRITICAL", "SSD Lifespan Wear Critical (>= 95%)"),
        ("WEAR_WARNING", "SSD Lifespan Wear High (>= 80%)"),
        ("ERROR_LOG_INCREASED", "NVMe Error Information Log Entries Increased"),
        ("NEW_UNSAFE_SHUTDOWN", "Abrupt Power Loss / Unsafe Shutdown Detected"),
        ("DISK_SPACE_CRITICAL", "Available Free Disk Space Critical"),
        ("DISK_SPACE_WARNING", "Available Free Disk Space Low"),
        ("CANARY_IO_FAILED", "Active Read/Write Canary Probe Failed"),
        ("CANARY_HIGH_LATENCY", "Active Canary Probe High Latency (> 300 ms)"),
        ("IO_DRIVER_ERRORS", "Kernel Block Driver Read/Write Errors"),
        ("IO_DRIVER_RETRIES", "Kernel Block Driver Retries Increased"),
        ("IO_LATENCY_CRITICAL", "Kernel Driver I/O Latency Critical (> 200 ms)"),
        ("IO_LATENCY_WARNING", "Kernel Driver I/O Latency Elevated (> 50 ms)"),
        ("USB_LINK_DEGRADED", "External Bus Link Speed Degraded / Downshifted"),
        ("VOLUME_UNMOUNTED", "Monitored Volume Unexpectedly Unmounted"),
        ("VOLUME_READONLY", "Writable Volume Remounted Read-Only"),
        ("VOLUME_VERIFY_FAILED", "File System Verification (fsck/diskutil) Failed"),
        ("REQUIRED_PATH_MISSING", "Required Critical Directory Path Missing"),
        ("HW_DISCONNECTED", "Physical Storage Hardware Disconnected"),
        ("HOST_THERMAL_CRITICAL", "Mac Host System Thermal Throttling")
    ]

    // MARK: - 1. Scope & Safety Guard Evaluation

    /// Returns true if `snapshot` matches the rule's configured `ActionDriveScope`.
    static func matchesScope(rule: ActionRule, snapshot: DiskHealthSnapshot) -> Bool {
        switch rule.scope {
        case .allDrives:
            return true
        case .externalOnly:
            return !snapshot.isInternal
        case .internalOnly:
            return snapshot.isInternal
        case .usbBusOnly:
            return snapshot.interconnectType.localizedCaseInsensitiveContains("USB")
        case .thunderboltBusOnly:
            return snapshot.interconnectType.localizedCaseInsensitiveContains("Thunderbolt")
        case .specificTarget:
            let filter = rule.specificTargetFilter.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !filter.isEmpty else { return true }
            let cleanFilter = filter.hasPrefix("/dev/") ? String(filter.dropFirst(5)) : filter
            return snapshot.driveKey.caseInsensitiveCompare(filter) == .orderedSame
                || snapshot.bsdName.caseInsensitiveCompare(cleanFilter) == .orderedSame
                || snapshot.mountPoint.caseInsensitiveCompare(filter) == .orderedSame
                || snapshot.serialNumber.caseInsensitiveCompare(filter) == .orderedSame
                || snapshot.productName.localizedCaseInsensitiveContains(filter)
        }
    }

    /// Returns true if the target drive/mount is a protected macOS boot/system volume
    /// that must never be unmounted, ejected, or remounted read-only by automation.
    static func isSystemProtectedMount(mountPoint: String, isInternal: Bool, bsdName: String) -> Bool {
        if isInternal {
            return true
        }
        let cleanBsd = bsdName.hasPrefix("/dev/") ? String(bsdName.dropFirst(5)) : bsdName
        if cleanBsd == "disk0" || cleanBsd.hasPrefix("disk0s") {
            return true
        }
        let m = mountPoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if m == "/" || m == "/System" || m.hasPrefix("/System/Volumes") || m.hasPrefix("/private/") {
            return true
        }
        return false
    }

    // MARK: - 2. Pure Functional Trigger Evaluation

    /// Evaluates whether a rule's condition is satisfied by the given snapshot and rate metrics.
    static func evaluateRuleCondition(
        rule: ActionRule,
        snapshot: DiskHealthSnapshot,
        previousSeverity: HealthSeverity? = nil,
        historyRates: HistoryRateMetrics = .zero
    ) -> (matched: Bool, triggerReason: String) {
        guard matchesScope(rule: rule, snapshot: snapshot) else {
            return (false, "Drive outside rule scope (\(rule.scope.displayName))")
        }

        let op = rule.conditionOperator
        let targetVal = rule.thresholdValue

        switch rule.triggerMetric {
        case .issueCode:
            let targetCode = rule.targetIssueCode.trimmingCharacters(in: .whitespacesAndNewlines)
            if targetCode.isEmpty || targetCode.uppercased() == "ANY" {
                if let firstIssue = snapshot.issues.first {
                    return (true, "Issue detected: [\(firstIssue.code)] \(firstIssue.title)")
                }
                return (false, "No active health issues")
            }
            if let matchedIssue = snapshot.issues.first(where: { $0.code.caseInsensitiveCompare(targetCode) == .orderedSame }) {
                return (true, "Issue [\(matchedIssue.code)]: \(matchedIssue.title)")
            }
            return (false, "Issue [\(targetCode)] not active")

        case .severityTransition:
            let desired = rule.targetIssueCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let currentRaw = snapshot.overallSeverity.rawValue.uppercased()
            let prev = previousSeverity ?? .healthy
            if desired == "RECOVERED" || desired == "HEALTHY" {
                if snapshot.overallSeverity == .healthy && prev != .healthy {
                    return (true, "Drive recovered from \(prev.rawValue) to HEALTHY")
                }
                return (false, "No recovery transition (current: \(currentRaw))")
            }
            let targetSeverity = HealthSeverity(rawValue: desired) ?? .critical
            if snapshot.overallSeverity == targetSeverity && prev != targetSeverity {
                return (true, "Severity transitioned from \(prev.rawValue) to \(targetSeverity.rawValue)")
            }
            return (false, "Severity did not transition to \(targetSeverity.rawValue)")

        case .temperatureCelsius:
            guard snapshot.smartValid else {
                return (false, "SMART temperature unavailable")
            }
            let actual = Double(snapshot.temperatureCelsius)
            let ok = op.evaluate(actual, targetVal)
            return (ok, String(format: "Temperature %.0f°C %@ %.0f°C", actual, op.rawValue, targetVal))

        case .freeSpaceGB:
            guard snapshot.isMounted && snapshot.totalBytes > 0 else {
                return (false, "Volume not mounted")
            }
            let actualGB = Double(snapshot.freeBytes) / 1_000_000_000.0
            let ok = op.evaluate(actualGB, targetVal)
            return (ok, String(format: "Free Space %.1f GB %@ %.1f GB", actualGB, op.rawValue, targetVal))

        case .usedPercent:
            guard snapshot.isMounted && snapshot.totalBytes > 0 else {
                return (false, "Volume not mounted")
            }
            let actual = snapshot.usedPercent
            let ok = op.evaluate(actual, targetVal)
            return (ok, String(format: "Space Used %.1f%% %@ %.1f%%", actual, op.rawValue, targetVal))

        case .healthScore:
            let actual = Double(snapshot.healthScore)
            let ok = op.evaluate(actual, targetVal)
            return (ok, String(format: "Health Score %.0f %@ %.0f", actual, op.rawValue, targetVal))

        case .avgWriteLatencyMs:
            guard snapshot.statsValid else {
                return (false, "Driver latency stats unavailable")
            }
            let actual = snapshot.avgWriteLatencyMs
            let ok = op.evaluate(actual, targetVal)
            return (ok, String(format: "Avg Write Latency %.1f ms %@ %.1f ms", actual, op.rawValue, targetVal))

        case .avgReadLatencyMs:
            guard snapshot.statsValid else {
                return (false, "Driver latency stats unavailable")
            }
            let actual = snapshot.avgReadLatencyMs
            let ok = op.evaluate(actual, targetVal)
            return (ok, String(format: "Avg Read Latency %.1f ms %@ %.1f ms", actual, op.rawValue, targetVal))

        case .writeThroughputMBps:
            guard snapshot.statsValid else {
                return (false, "Driver throughput stats unavailable")
            }
            let actual = snapshot.writeThroughputMBps
            let ok = op.evaluate(actual, targetVal)
            return (ok, String(format: "Write Throughput %.1f MB/s %@ %.1f MB/s", actual, op.rawValue, targetVal))

        case .percentageUsed:
            guard snapshot.smartValid else {
                return (false, "SMART wear percentage unavailable")
            }
            let actual = Double(snapshot.percentageUsed)
            let ok = op.evaluate(actual, targetVal)
            return (ok, String(format: "SSD Wear %.0f%% %@ %.0f%%", actual, op.rawValue, targetVal))

        case .availableSpare:
            guard snapshot.smartValid else {
                return (false, "SMART available spare unavailable")
            }
            let actual = Double(snapshot.availableSpare)
            let ok = op.evaluate(actual, targetVal)
            return (ok, String(format: "Available Spare %.0f%% %@ %.0f%%", actual, op.rawValue, targetVal))

        case .dailyTerabytesWritten:
            let actual = max(snapshot.dailyTerabytesWritten, historyRates.terabytesWrittenLast24h)
            let ok = op.evaluate(actual, targetVal)
            return (ok, String(format: "24h Write Rate %.2f TB/day %@ %.2f TB/day", actual, op.rawValue, targetVal))

        case .freeSpaceDropGBPerHour:
            let actual = historyRates.freeSpaceDropGBPerHour
            let ok = op.evaluate(actual, targetVal)
            return (ok, String(format: "Free Space Drop %.2f GB/hr %@ %.2f GB/hr", actual, op.rawValue, targetVal))
        }
    }

    // MARK: - 3. Stateful Hysteresis, Cooldown & Execution Pipeline

    /// Evaluates all enabled rules in `config.actionRules` for `snapshot`, updating poll counters,
    /// cooldown timestamps, and `recentActionExecutions` in `state`.
    func evaluateAndExecuteRules(
        for snapshot: DiskHealthSnapshot,
        previousSeverity: HealthSeverity?,
        state: inout DiskPersistentState,
        config: DiskHealthConfig,
        historyRates: HistoryRateMetrics,
        nowTs: TimeInterval,
        forceDryRun: Bool = false
    ) -> [ActionExecutionRecord] {
        guard config.enableActionRulesEngine else { return [] }

        var records: [ActionExecutionRecord] = []

        for rule in config.actionRules where rule.isEnabled {
            let scopedRuleKey = "\(rule.id):\(snapshot.driveKey)"
            let (matched, reason) = Self.evaluateRuleCondition(
                rule: rule,
                snapshot: snapshot,
                previousSeverity: previousSeverity,
                historyRates: historyRates
            )

            if !matched {
                state.consecutiveRuleMatchPollsById[scopedRuleKey] = 0
                continue
            }

            let consecutive = (state.consecutiveRuleMatchPollsById[scopedRuleKey] ?? 0) + 1
            state.consecutiveRuleMatchPollsById[scopedRuleKey] = consecutive

            let requiredPolls = max(1, rule.requiredConsecutivePolls)
            if consecutive < requiredPolls {
                ConfigManager.shared.log(
                    "Automation rule '\(rule.name)' matched poll \(consecutive)/\(requiredPolls) on \(snapshot.displayLabel) (\(reason)); waiting for sustained confirmation."
                )
                continue
            }

            // Check per-rule, per-drive cooldown
            let lastFired = state.lastRuleFiredTimestampById[scopedRuleKey] ?? 0
            let cooldown = max(60.0, rule.cooldownSeconds)
            if lastFired > 0 && (nowTs - lastFired) < cooldown {
                continue
            }

            // Mark cooldown timestamp before executing action to prevent re-entrancy storms
            state.lastRuleFiredTimestampById[scopedRuleKey] = nowTs

            let isDryRun = forceDryRun || rule.dryRunOnly
            let record = executeRuleAction(
                rule: rule,
                snapshot: snapshot,
                triggerReason: reason,
                nowTs: nowTs,
                dryRun: isDryRun
            )
            records.append(record)
            appendAuditRecord(record, to: &state)
        }

        return records
    }

    /// Appends an `ActionExecutionRecord` to `state.recentActionExecutions` (bounded to newest 50).
    func appendAuditRecord(_ record: ActionExecutionRecord, to state: inout DiskPersistentState) {
        state.recentActionExecutions.insert(record, at: 0)
        if state.recentActionExecutions.count > Self.maxAuditHistoryRecords {
            state.recentActionExecutions.removeLast(state.recentActionExecutions.count - Self.maxAuditHistoryRecords)
        }
    }

    // MARK: - 4. Concrete Action Execution & Safety Guards

    /// Executes or dry-runs a single `ActionRule` action and returns its `ActionExecutionRecord`.
    func executeRuleAction(
        rule: ActionRule,
        snapshot: DiskHealthSnapshot,
        triggerReason: String,
        nowTs: TimeInterval = Date().timeIntervalSince1970,
        dryRun: Bool = false
    ) -> ActionExecutionRecord {
        let formattedTime = isoTimestampFormatter.string(from: Date(timeIntervalSince1970: nowTs))

        // Enforce mandatory system boot drive protection before any unmount/eject/read-only action
        if rule.actionType.isMutatingMountAction {
            if Self.isSystemProtectedMount(
                mountPoint: snapshot.mountPoint,
                isInternal: snapshot.isInternal,
                bsdName: snapshot.bsdName
            ) {
                let msg = "Blocked by Safety Guard: Refusing to run \(rule.actionType.shortBadgeTitle) on internal/system drive '\(snapshot.displayLabel)' (mount: \(snapshot.mountPoint.isEmpty ? "none" : snapshot.mountPoint))."
                ConfigManager.shared.log("[AutomationRule] \(msg)")
                return ActionExecutionRecord(
                    id: UUID().uuidString,
                    timestamp: nowTs,
                    formattedTime: formattedTime,
                    ruleId: rule.id,
                    ruleName: rule.name,
                    driveKey: snapshot.driveKey,
                    driveDisplayName: snapshot.displayLabel,
                    actionType: rule.actionType,
                    status: .blockedBySafetyGuard,
                    triggerReason: triggerReason,
                    outputDetail: msg
                )
            }
        }

        if dryRun {
            let msg = "[DRY-RUN] Would execute '\(rule.actionType.displayName)' on \(snapshot.displayLabel) because \(triggerReason)."
            ConfigManager.shared.log("[AutomationRule] \(msg)")
            return ActionExecutionRecord(
                id: UUID().uuidString,
                timestamp: nowTs,
                formattedTime: formattedTime,
                ruleId: rule.id,
                ruleName: rule.name,
                driveKey: snapshot.driveKey,
                driveDisplayName: snapshot.displayLabel,
                actionType: rule.actionType,
                status: .dryRun,
                triggerReason: triggerReason,
                outputDetail: msg
            )
        }

        let (status, detail) = performLiveAction(rule: rule, snapshot: snapshot, triggerReason: triggerReason)
        ConfigManager.shared.log("[AutomationRule] Rule '\(rule.name)' [\(status.rawValue)] on \(snapshot.displayLabel): \(detail)")

        return ActionExecutionRecord(
            id: UUID().uuidString,
            timestamp: nowTs,
            formattedTime: formattedTime,
            ruleId: rule.id,
            ruleName: rule.name,
            driveKey: snapshot.driveKey,
            driveDisplayName: snapshot.displayLabel,
            actionType: rule.actionType,
            status: status,
            triggerReason: triggerReason,
            outputDetail: detail
        )
    }

    private func performLiveAction(
        rule: ActionRule,
        snapshot: DiskHealthSnapshot,
        triggerReason: String
    ) -> (ActionExecutionStatus, String) {
        switch rule.actionType {
        case .sendNotification:
            let title = "⚡ Rule Triggered: \(rule.name)"
            let body = "\(snapshot.displayLabel) — \(triggerReason)"
            if ConfigManager.shared.currentConfig.enableNativeNotifications {
                MacOSNotifier.shared.postNotification(
                    title: title,
                    subtitle: "Score: \(snapshot.healthScore)/100 (\(snapshot.overallSeverity.rawValue))",
                    body: body,
                    identifier: "disk-health-rule-\(rule.id)"
                )
            }
            let html = TelegramNotifier.shared.formatReportHTML(snapshot: snapshot, title: "\(title) (\(triggerReason))")
            TelegramNotifier.shared.sendMessageAsync(htmlText: html, disableNotification: false)
            WebhookNotifier.shared.sendWebhookAsync(snapshot: snapshot, title: title, eventType: "automation_rule_triggered")
            return (.succeeded, "Dispatched alert notification for '\(rule.name)' (\(triggerReason)).")

        case .safeUnmountDrive:
            let target = !snapshot.mountPoint.isEmpty ? snapshot.mountPoint : (!snapshot.bsdName.isEmpty ? "/dev/\(snapshot.bsdName)" : "")
            guard !target.isEmpty else {
                return (.failed, "Cannot unmount: no mount point or BSD name on snapshot.")
            }
            let res = Self.runSandboxedCommand(
                executablePath: "/usr/sbin/diskutil",
                arguments: ["unmount", target],
                timeoutSec: 20.0
            )
            return res.ok ? (.succeeded, "Unmounted '\(target)': \(res.output)") : (.failed, "diskutil unmount failed: \(res.output)")

        case .safeEjectDrive:
            let target = !snapshot.bsdName.isEmpty ? "/dev/\(snapshot.bsdName)" : snapshot.mountPoint
            guard !target.isEmpty else {
                return (.failed, "Cannot eject: no BSD device name or mount point available.")
            }
            let res = Self.runSandboxedCommand(
                executablePath: "/usr/sbin/diskutil",
                arguments: ["eject", target],
                timeoutSec: 25.0
            )
            return res.ok ? (.succeeded, "Ejected '\(target)': \(res.output)") : (.failed, "diskutil eject failed: \(res.output)")

        case .remountReadOnly:
            guard snapshot.isMounted && !snapshot.mountPoint.isEmpty else {
                return (.failed, "Cannot remount read-only: volume is not currently mounted.")
            }
            let res = Self.runSandboxedCommand(
                executablePath: "/sbin/mount",
                arguments: ["-u", "-r", snapshot.mountPoint],
                timeoutSec: 15.0
            )
            return res.ok
                ? (.succeeded, "Volume '\(snapshot.mountPoint)' locked to Read-Only mode.")
                : (.failed, "mount -u -r failed on '\(snapshot.mountPoint)': \(res.output)")

        case .startTimeMachineBackup:
            let res = Self.runSandboxedCommand(
                executablePath: "/usr/bin/tmutil",
                arguments: ["startbackup", "--auto"],
                timeoutSec: 15.0
            )
            return res.ok
                ? (.succeeded, "Triggered background Time Machine auto-backup (tmutil startbackup --auto).")
                : (.failed, "tmutil startbackup failed: \(res.output)")

        case .thinApfsSnapshots:
            let mountTarget = snapshot.mountPoint.isEmpty ? "/" : snapshot.mountPoint
            guard snapshot.filesystemType.lowercased() == "apfs" || mountTarget == "/" else {
                return (.failed, "APFS snapshot thinning skipped: '\(mountTarget)' is not an APFS volume (\(snapshot.filesystemType)).")
            }
            // Request thinning up to 10 GB (10_737_418_240 bytes) with urgency 4
            let res = Self.runSandboxedCommand(
                executablePath: "/usr/bin/tmutil",
                arguments: ["thinLocalSnapshots", mountTarget, "10737418240", "4"],
                timeoutSec: 30.0
            )
            return res.ok
                ? (.succeeded, "Thinned APFS local snapshots on '\(mountTarget)': \(res.output.isEmpty ? "Completed" : res.output)")
                : (.failed, "tmutil thinLocalSnapshots failed: \(res.output)")

        case .runVolumeVerification:
            let mountTarget = !snapshot.mountPoint.isEmpty ? snapshot.mountPoint : (!snapshot.bsdName.isEmpty ? "/dev/\(snapshot.bsdName)" : "/")
            DispatchQueue.global(qos: .utility).async {
                DiskHealthMonitor.shared.runVolumeVerification(
                    targetMountOverride: mountTarget,
                    driveKeyOverride: snapshot.driveKey,
                    sendTelegram: true
                )
            }
            return (.succeeded, "Initiated asynchronous diskutil verifyVolume on '\(mountTarget)'.")

        case .runQuickSurfaceScan:
            DispatchQueue.global(qos: .utility).async {
                _ = DiskHealthMonitor.shared.runSurfaceReadScan(mode: .quick)
            }
            return (.succeeded, "Initiated asynchronous Quick F_NOCACHE surface scan.")

        case .exportHtmlReport:
            if let savedPath = DiagnosticExporter.shared.saveDiagnosticReportHTMLToFile(at: nil) {
                return (.succeeded, "Exported standalone HTML RMA report to \(savedPath)")
            }
            return (.failed, "Failed to write HTML diagnostic report.")

        case .captureTopIoProcesses:
            let culprits = ProcessIoInspector.shared.sampleActiveCulpritsWindow(durationSec: 0.25, topN: 5)
            if culprits.isEmpty {
                return (.succeeded, "Sampled process I/O: no active disk I/O processes detected.")
            }
            let summary = culprits.map(\.formattedSummary).joined(separator: " | ")
            return (.succeeded, "Top Disk I/O Processes: \(summary)")

        case .runMacShortcut:
            let shortcutName = rule.actionParameter.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !shortcutName.isEmpty else {
                return (.failed, "No macOS Shortcut name specified in rule parameter.")
            }
            let res = Self.runSandboxedCommand(
                executablePath: "/usr/bin/shortcuts",
                arguments: ["run", shortcutName],
                timeoutSec: 20.0
            )
            return res.ok
                ? (.succeeded, "Executed macOS Shortcut '\(shortcutName)'.")
                : (.failed, "macOS Shortcut '\(shortcutName)' failed: \(res.output)")

        case .runCustomScript:
            let rawPath = rule.actionParameter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? ConfigManager.shared.resolvedAlertScriptPath.trimmingCharacters(in: .whitespacesAndNewlines)
                : rule.actionParameter.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawPath.isEmpty else {
                return (.failed, "No script path configured for rule '\(rule.name)'.")
            }
            let expandedPath = (rawPath as NSString).expandingTildeInPath
            guard FileManager.default.isExecutableFile(atPath: expandedPath) else {
                return (.failed, "Script '\(expandedPath)' does not exist or is not executable (chmod +x).")
            }
            guard ConfigManager.isSecureUserOwnedFile(atPath: expandedPath) else {
                return (.failed, "Security check failed: Script '\(expandedPath)' must be owned by current user/root and not group/world-writable.")
            }

            var env = DiskHealthMonitor.makeRuleScriptEnvironment(
                snapshot: snapshot,
                rule: rule,
                triggerReason: triggerReason
            )
            env["DISK_HEALTH_EVENT"] = "automation_rule"
            let res = Self.runSandboxedCommand(
                executablePath: expandedPath,
                arguments: [],
                environment: env,
                timeoutSec: 15.0
            )
            return res.ok
                ? (.succeeded, "Script '\((expandedPath as NSString).lastPathComponent)' exited 0: \(res.output.isEmpty ? "(no output)" : res.output)")
                : (.failed, "Script '\((expandedPath as NSString).lastPathComponent)' failed: \(res.output)")
        }
    }

    // MARK: - 5. Synthetic Snapshot Generator for Rule Simulation (`--simulate-rule` & UI)

    /// Constructs a synthetic `DiskHealthSnapshot` guaranteed to trigger `rule` for dry-run testing.
    static func makeSyntheticMatchingSnapshot(
        for rule: ActionRule,
        baseSnapshot: DiskHealthSnapshot? = nil
    ) -> (snapshot: DiskHealthSnapshot, previousSeverity: HealthSeverity, historyRates: HistoryRateMetrics) {
        let nowTs = Date().timeIntervalSince1970
        let isInternal: Bool = {
            switch rule.scope {
            case .externalOnly, .usbBusOnly, .thunderboltBusOnly:
                return false
            case .internalOnly:
                return true
            case .allDrives, .specificTarget:
                if rule.actionType.isMutatingMountAction {
                    return false // Use external synthetic drive so dry-run demonstrates trigger + action
                }
                return baseSnapshot?.isInternal ?? false
            }
        }()

        let interconnect: String = {
            switch rule.scope {
            case .usbBusOnly: return "USB"
            case .thunderboltBusOnly: return "Thunderbolt"
            default: return isInternal ? "Apple Fabric" : "USB"
            }
        }()

        let bsdName = (!rule.specificTargetFilter.isEmpty && rule.specificTargetFilter.hasPrefix("disk"))
            ? rule.specificTargetFilter
            : (isInternal ? "disk0" : "disk6")
        let mountPoint = isInternal ? "/" : "/Volumes/SimulatedExternalSSD"

        var tempC = 42
        var freeBytes: UInt64 = 250_000_000_000
        let totalBytes: UInt64 = 1_000_000_000_000
        var usedPct = 75.0
        var healthScore = 92
        var writeLatMs = 2.5
        var readLatMs = 1.8
        var writeMBps = 120.0
        var wearPct: UInt8 = 12
        var sparePct: UInt8 = 100
        var tbWritten = 15.0
        var overallSeverity: HealthSeverity = .warning
        var prevSeverity: HealthSeverity = .healthy
        var issues: [HealthIssue] = []
        var historyRates = HistoryRateMetrics.zero

        let delta: Double = {
            switch rule.conditionOperator {
            case .greaterThan: return 2.0
            case .lessThan: return -2.0
            case .greaterThanOrEqual, .lessThanOrEqual, .equals: return 0.0
            }
        }()
        let targetVal = rule.thresholdValue + delta

        switch rule.triggerMetric {
        case .issueCode:
            let code = rule.targetIssueCode.isEmpty ? "TEMP_CRITICAL" : rule.targetIssueCode
            overallSeverity = .critical
            healthScore = 55
            issues.append(HealthIssue(
                code: code,
                severity: .critical,
                title: "Simulated Issue (\(code))",
                detail: "Synthetic diagnostic trigger for rule '\(rule.name)'."
            ))
        case .severityTransition:
            let desired = rule.targetIssueCode.uppercased()
            if desired == "RECOVERED" || desired == "HEALTHY" {
                prevSeverity = .critical
                overallSeverity = .healthy
                healthScore = 100
            } else if desired == "WARNING" {
                prevSeverity = .healthy
                overallSeverity = .warning
                healthScore = 80
            } else {
                prevSeverity = .healthy
                overallSeverity = .critical
                healthScore = 50
            }
        case .temperatureCelsius:
            tempC = max(1, Int(targetVal.rounded()))
        case .freeSpaceGB:
            freeBytes = UInt64(max(0.1, targetVal) * 1_000_000_000.0)
            usedPct = min(99.9, max(1.0, (1.0 - (Double(freeBytes) / Double(totalBytes))) * 100.0))
        case .usedPercent:
            usedPct = min(99.9, max(0.0, targetVal))
            freeBytes = UInt64(Double(totalBytes) * (1.0 - usedPct / 100.0))
        case .healthScore:
            healthScore = max(0, min(100, Int(targetVal.rounded())))
        case .avgWriteLatencyMs:
            writeLatMs = max(0.1, targetVal)
        case .avgReadLatencyMs:
            readLatMs = max(0.1, targetVal)
        case .writeThroughputMBps:
            writeMBps = max(0.1, targetVal)
        case .percentageUsed:
            wearPct = UInt8(max(0, min(100, Int(targetVal.rounded()))))
        case .availableSpare:
            sparePct = UInt8(max(0, min(100, Int(targetVal.rounded()))))
        case .dailyTerabytesWritten:
            tbWritten = max(0.1, targetVal) * 10.0
            historyRates = HistoryRateMetrics(freeSpaceDropGBPerHour: 0.0, terabytesWrittenLast24h: max(0.01, targetVal))
        case .freeSpaceDropGBPerHour:
            historyRates = HistoryRateMetrics(freeSpaceDropGBPerHour: max(0.01, targetVal), terabytesWrittenLast24h: 0.5)
        }

        let snap = DiskHealthSnapshot(
            timestamp: nowTs,
            formattedTime: isoTimestampFormatter.string(from: Date(timeIntervalSince1970: nowTs)),
            formattedShortTime: shortTimeFormatter.string(from: Date(timeIntervalSince1970: nowTs)),
            overallSeverity: overallSeverity,
            healthScore: healthScore,
            issues: issues,
            hardwareFound: true,
            vendorName: baseSnapshot?.vendorName ?? "Simulated",
            productName: baseSnapshot?.productName ?? (isInternal ? "Apple SSD" : "External NVMe Pro"),
            productRevision: "1.0",
            bsdName: bsdName,
            serialNumber: (!rule.specificTargetFilter.isEmpty && rule.scope == .specificTarget) ? rule.specificTargetFilter : "SIM-SN-2026",
            usbSerialNumber: "SIM-SN-2026",
            interconnectType: interconnect,
            protocolType: "NVMe",
            isInternal: isInternal,
            isRemovable: !isInternal,
            linkSpeedBps: 10_000_000_000,
            linkSpeedFormatted: "10 Gbps",
            isMounted: true,
            mountPoint: mountPoint,
            filesystemType: "apfs",
            isReadOnly: false,
            totalBytes: totalBytes,
            freeBytes: freeBytes,
            purgeableBytes: 0,
            usedBytes: totalBytes > freeBytes ? (totalBytes - freeBytes) : 0,
            usedPercent: usedPct,
            subpathsStatus: [:],
            canaryOk: true,
            canaryLatencyMs: 1.5,
            canaryError: "",
            smartValid: true,
            criticalWarning: 0,
            temperatureCelsius: tempC,
            temperatureKelvin: tempC + 273,
            peakTemperatureCelsius: max(tempC, 45),
            availableSpare: sparePct,
            availableSpareThreshold: 10,
            percentageUsed: wearPct,
            lifeRemainingPercent: max(0, 100 - Int(wearPct)),
            dataUnitsRead: 10_000,
            dataUnitsWritten: 10_000,
            totalTerabytesRead: 10.0,
            totalTerabytesWritten: tbWritten,
            hostReadCommands: 100_000,
            hostWriteCommands: 100_000,
            controllerBusyTime: 10,
            powerCycles: 25,
            powerOnHours: 240,
            unsafeShutdowns: 0,
            mediaErrors: issues.contains(where: { $0.code == "MEDIA_ERRORS" }) ? 1 : 0,
            errorInfoLogEntries: 0,
            statsValid: true,
            sessionBytesRead: 1_000_000_000,
            sessionBytesWritten: 1_000_000_000,
            operationsRead: 50_000,
            operationsWritten: 50_000,
            errorsRead: 0,
            errorsWritten: 0,
            retriesRead: 0,
            retriesWritten: 0,
            avgReadLatencyMs: readLatMs,
            avgWriteLatencyMs: writeLatMs,
            readThroughputMBps: 100.0,
            writeThroughputMBps: writeMBps,
            lastVerifyResult: "Verified OK",
            lastVerifyOk: true,
            customDriveKey: (!rule.specificTargetFilter.isEmpty && rule.scope == .specificTarget) ? rule.specificTargetFilter : nil,
            usbCurrentAvailableMa: isInternal ? 0 : 900,
            usbCurrentRequiredMa: isInternal ? 0 : 500,
            linkWidthLanes: isInternal ? 4 : 0
        )

        return (snap, prevSeverity, historyRates)
    }

    // MARK: - 6. Sandboxed Subprocess Runner with Watchdog & Pipe Drain

    static func runSandboxedCommand(
        executablePath: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeoutSec: TimeInterval = 15.0
    ) -> (ok: Bool, output: String) {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            return (false, "Executable not found at \(executablePath)")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = arguments
        if let env = environment {
            proc.environment = env
        }
        let pipeOut = Pipe()
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = pipeOut
        proc.standardError = pipeOut
        let readHandle = pipeOut.fileHandleForReading

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
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0, execute: escalation)
                }
            }
            watchdog.resume()

            // Invariant (PROC-PIPE-01): Drain pipe BEFORE waitUntilExit() to prevent 64KB buffer deadlock
            let outData = readHandle.readDataToEndOfFile()
            try? readHandle.close()

            proc.waitUntilExit()
            watchdog.cancel()
            timeoutLock.lock()
            killWorkItem?.cancel()
            let didTimeout = timedOut
            timeoutLock.unlock()

            let outStr = (String(data: outData, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if didTimeout {
                return (false, "Timed out after \(Int(timeoutSec))s")
            }
            return (proc.terminationStatus == 0, outStr)
        } catch {
            try? readHandle.close()
            return (false, error.localizedDescription)
        }
    }
}
