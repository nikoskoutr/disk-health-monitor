// ============================================================================
// File: AlertCoordinator.swift
// Module: Layer 3 (Notifications & Alerting)
// Purpose: Coordinates alert hysteresis, cooldown enforcement, baseline advancement,
//          recovery notifications, daily digests, sandboxed alert scripts, and
//          asynchronous dispatch across macOS, Telegram, and Webhooks.
// Concurrency: Thread-safe DispatchGroup synchronization; mutates state under caller lock.
// ============================================================================

import Foundation
import AppKit

/// Synchronized ISO 8601 date formatter for daily summary digest comparisons.
private let dailyDigestDateFormatter: SynchronizedDateFormatter = {
    let df = SynchronizedDateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.dateFormat = "yyyy-MM-dd"
    return df
}()

/// Coordinates alert cooldowns, transient hysteresis, daily digests, and notification channels.
final class AlertCoordinator: @unchecked Sendable {
    static let shared = AlertCoordinator()

    private static let transientWarningCodes: Set<String> = [
        "IO_LATENCY_WARNING",
        "CANARY_HIGH_LATENCY",
        "TEMP_RAPID_RISE"
    ]

    private let notificationGroup = DispatchGroup()

    private init() {}

    func waitForPendingNotifications(timeout: TimeInterval = 16.0) {
        _ = notificationGroup.wait(timeout: .now() + timeout)
    }

    /// Evaluates alert hysteresis, dispatches multi-channel notifications, runs declarative automation rules,
    /// and schedules the daily digest for one monitored drive under the caller's state lock.
    func processAlertsAndDigestLocked(
        snapshot: DiskHealthSnapshot,
        rawMetrics hw: DiskHardwareMetrics,
        driveKey: String,
        state: inout DiskPersistentState,
        config cfg: DiskHealthConfig,
        onActionLogUpdated: ([ActionExecutionRecord]) -> Void
    ) {
        let nowTs = snapshot.timestamp
        let cooldown = cfg.alertCooldownSeconds
        var shouldSendAlert = false
        var deferSeverityUpdateForHysteresis = false

        if snapshot.overallSeverity != .healthy && !snapshot.issues.isEmpty {
            var currentUnhealthyPolls = 1
            state.updateDriveState(key: driveKey) {
                $0.consecutiveUnhealthyPolls += 1
                $0.consecutiveHealthyPolls = 0
                currentUnhealthyPolls = $0.consecutiveUnhealthyPolls
            }

            let isPurelyTransientSpike = snapshot.overallSeverity == .warning &&
                snapshot.issues.allSatisfy { Self.transientWarningCodes.contains($0.code) }

            if isPurelyTransientSpike && currentUnhealthyPolls < 2 {
                deferSeverityUpdateForHysteresis = true
            } else {
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
                state.updateDriveState(key: driveKey) { $0.baselineUnsafeShutdowns = hw.unsafeShutdowns }
            }
            if snapshot.issues.contains(where: { $0.code == "ERROR_LOG_INCREASED" }) && hw.smartValid {
                state.updateDriveState(key: driveKey) { $0.baselineErrorLogEntries = hw.errorInfoLogEntries }
            }
            if snapshot.issues.contains(where: { $0.code == "IO_DRIVER_RETRIES" }) && hw.statsValid {
                state.updateDriveState(key: driveKey) {
                    $0.baselineIoReadRetries = hw.retriesRead
                    $0.baselineIoWriteRetries = hw.retriesWritten
                }
            }
            if snapshot.issues.contains(where: { $0.code == "IO_DRIVER_ERRORS" }) && hw.statsValid {
                state.updateDriveState(key: driveKey) {
                    $0.baselineIoReadErrors = hw.errorsRead
                    $0.baselineIoWriteErrors = hw.errorsWritten
                }
            }
            if snapshot.issues.contains(where: { $0.code == "MEDIA_ERRORS" }) && hw.smartValid {
                state.updateDriveState(key: driveKey) {
                    $0.baselineMediaErrors = hw.mediaErrors
                }
            }
            if snapshot.issues.contains(where: { $0.code == "BUS_PHY_ERRORS" }) && hw.found {
                state.updateDriveState(key: driveKey) {
                    $0.baselineBusErrors = hw.busErrorCount
                    $0.baselineBusResets = hw.busResetCount
                }
            }

            state.updateDriveState(key: driveKey) {
                $0.lastNotifiedSeverity = snapshot.overallSeverity.rawValue
            }

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
            var driveState = state.getDriveState(key: driveKey)
            driveState.consecutiveHealthyPolls += 1
            driveState.consecutiveUnhealthyPolls = 0

            let previouslyAlerted = driveState.lastNotifiedSeverity != HealthSeverity.healthy.rawValue
            if previouslyAlerted && driveState.consecutiveHealthyPolls >= 2 {
                let recoveryTitle = "\(snapshot.productName) RECOVERED — HEALTHY"
                ConfigManager.shared.log("Drive \(driveKey) recovered to HEALTHY state.")
                driveState.lastNotifiedSeverity = HealthSeverity.healthy.rawValue
                driveState.lastRecoveryTimestamp = nowTs

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

        let prevOverallSeverity = HealthSeverity(rawValue: state.getDriveState(key: driveKey).lastOverallSeverity)
        if !deferSeverityUpdateForHysteresis {
            state.updateDriveState(key: driveKey) {
                $0.lastOverallSeverity = snapshot.overallSeverity.rawValue
            }
        }

        let historyRates = TelemetryHistoryStore.shared.computeRateMetrics(for: snapshot)
        let executedRecords = ActionRuleEngine.shared.evaluateAndExecuteRules(
            for: snapshot,
            previousSeverity: prevOverallSeverity,
            state: &state,
            config: cfg,
            historyRates: historyRates,
            nowTs: nowTs,
            forceDryRun: false
        )
        if !executedRecords.isEmpty {
            onActionLogUpdated(state.recentActionExecutions)
        }

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

    static func makeCleanAlertScriptEnvironment(snapshot: DiskHealthSnapshot, title: String, eventType: String) -> [String: String] {
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

    static func makeRuleScriptEnvironment(snapshot: DiskHealthSnapshot, rule: ActionRule, triggerReason: String) -> [String: String] {
        var env = makeCleanAlertScriptEnvironment(
            snapshot: snapshot,
            title: "Automation Rule: \(rule.name)",
            eventType: "automation_rule"
        )
        env["DISK_HEALTH_RULE_ID"] = rule.id
        env["DISK_HEALTH_RULE_NAME"] = rule.name
        env["DISK_HEALTH_TRIGGER_REASON"] = triggerReason
        env["DISK_HEALTH_ACTION_TYPE"] = rule.actionType.rawValue
        return env
    }

    func testAlertScriptResult(snapshot: DiskHealthSnapshot, timeoutSec: TimeInterval = 15.0) -> Result<String, DiskHealthError> {
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

        let cleanEnv = Self.makeCleanAlertScriptEnvironment(snapshot: snapshot, title: "\(snapshot.productName) Alert Script Test", eventType: "test_alert")
        let runResult = SubprocessRunner.run(
            executable: expandedPath,
            arguments: [],
            environment: cleanEnv,
            timeoutSeconds: timeoutSec
        )

        let outputStr = runResult.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let outSuffix = outputStr.isEmpty ? "" : "\n\(outputStr)"
        if runResult.timedOut {
            return .failure(.scriptExecutionFailed(exitCode: -1, output: "❌ Alert script timed out after \(Int(timeoutSec))s.\(outSuffix)"))
        }
        if runResult.exitCode == 0 {
            return .success("✅ Alert script executed successfully (exit code 0).\(outSuffix)")
        } else {
            return .failure(.scriptExecutionFailed(exitCode: runResult.exitCode, output: "❌ Alert script failed with exit code \(runResult.exitCode).\(outSuffix)"))
        }
    }

    func executeAlertScriptAsync(snapshot: DiskHealthSnapshot, title: String, eventType: String) {
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
            let cleanEnv = Self.makeCleanAlertScriptEnvironment(snapshot: snapshot, title: title, eventType: eventType)
            let runResult = SubprocessRunner.run(
                executable: expandedPath,
                arguments: [],
                environment: cleanEnv,
                timeoutSeconds: 15.0
            )
            if runResult.timedOut {
                ConfigManager.shared.log("Alert script timed out after 15s (\(expandedPath))")
            } else {
                ConfigManager.shared.log("Alert script executed (\(expandedPath)): exit=\(runResult.exitCode)")
            }
        }
    }
}
