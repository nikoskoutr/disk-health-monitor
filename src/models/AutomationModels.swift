// ============================================================================
// File: AutomationModels.swift
// Module: Layer 2 (Infrastructure & Models)
// Purpose: Declarative "When X, Do Y" rule-based automation models, trigger
//          metrics, scopes, action execution types, presets, and audit records.
// Concurrency: Pure Sendable value types.
// ============================================================================

import Foundation

/// Telemetry metric or discrete event evaluated by an `ActionRule` trigger.
enum ActionTriggerMetric: String, Codable, CaseIterable, Sendable, Equatable {
    case issueCode = "ISSUE_CODE"
    case temperatureCelsius = "TEMP_CELSIUS"
    case freeSpaceGB = "FREE_SPACE_GB"
    case usedPercent = "USED_PERCENT"
    case healthScore = "HEALTH_SCORE"
    case avgWriteLatencyMs = "AVG_WRITE_LATENCY_MS"
    case avgReadLatencyMs = "AVG_READ_LATENCY_MS"
    case writeThroughputMBps = "WRITE_THROUGHPUT_MBPS"
    case percentageUsed = "SSD_WEAR_PERCENT"
    case availableSpare = "SSD_SPARE_PERCENT"
    case dailyTerabytesWritten = "DAILY_TBW_RATE"
    case freeSpaceDropGBPerHour = "FREE_SPACE_DROP_GB_HR"
    case severityTransition = "SEVERITY_TRANSITION"
    case systemWillSleep = "SYSTEM_WILL_SLEEP"

    var displayName: String {
        switch self {
        case .issueCode: return "Health Issue Code Detected"
        case .temperatureCelsius: return "Drive Temperature (°C)"
        case .freeSpaceGB: return "Available Free Space (GB)"
        case .usedPercent: return "Disk Space Used (%)"
        case .healthScore: return "Overall Health Score (0–100)"
        case .avgWriteLatencyMs: return "Average Write Latency (ms)"
        case .avgReadLatencyMs: return "Average Read Latency (ms)"
        case .writeThroughputMBps: return "Write Throughput (MB/s)"
        case .percentageUsed: return "SSD Wear Level (%)"
        case .availableSpare: return "SSD Available Spare (%)"
        case .dailyTerabytesWritten: return "24h Write Burn Rate (TB/day)"
        case .freeSpaceDropGBPerHour: return "Free Space Drop Rate (GB/hr)"
        case .severityTransition: return "Health Severity Transition"
        case .systemWillSleep: return "System Power Pre-Sleep Event"
        }
    }

    var unitSuffix: String {
        switch self {
        case .issueCode, .severityTransition, .systemWillSleep: return ""
        case .temperatureCelsius: return "°C"
        case .freeSpaceGB: return "GB"
        case .usedPercent, .percentageUsed, .availableSpare: return "%"
        case .healthScore: return "pts"
        case .avgWriteLatencyMs, .avgReadLatencyMs: return "ms"
        case .writeThroughputMBps: return "MB/s"
        case .dailyTerabytesWritten: return "TB/d"
        case .freeSpaceDropGBPerHour: return "GB/h"
        }
    }

    var usesNumericThreshold: Bool {
        switch self {
        case .issueCode, .severityTransition, .systemWillSleep:
            return false
        default:
            return true
        }
    }
}

/// Relational operator comparing a numeric telemetry value against `thresholdValue`.
enum ActionConditionOperator: String, Codable, CaseIterable, Sendable, Equatable {
    case greaterThanOrEqual = ">="
    case lessThanOrEqual = "<="
    case greaterThan = ">"
    case lessThan = "<"
    case equals = "=="

    func evaluate(_ lhs: Double, _ rhs: Double) -> Bool {
        switch self {
        case .greaterThanOrEqual: return lhs >= rhs
        case .lessThanOrEqual: return lhs <= rhs
        case .greaterThan: return lhs > rhs
        case .lessThan: return lhs < rhs
        case .equals: return abs(lhs - rhs) < 0.0001
        }
    }
}

/// Target drive scope filtering which storage devices an `ActionRule` applies to.
enum ActionDriveScope: String, Codable, CaseIterable, Sendable, Equatable {
    case allDrives = "ALL_DRIVES"
    case externalOnly = "EXTERNAL_ONLY"
    case internalOnly = "INTERNAL_ONLY"
    case usbBusOnly = "USB_ONLY"
    case thunderboltBusOnly = "THUNDERBOLT_ONLY"
    case specificTarget = "SPECIFIC_TARGET"

    var displayName: String {
        switch self {
        case .allDrives: return "All Monitored Drives"
        case .externalOnly: return "External Drives Only"
        case .internalOnly: return "Internal Drives Only"
        case .usbBusOnly: return "USB Bus Drives Only"
        case .thunderboltBusOnly: return "Thunderbolt Drives Only"
        case .specificTarget: return "Specific Drive / Mount"
        }
    }
}

/// Automated remediation or diagnostic action executed when an `ActionRule` fires.
enum ActionExecutionType: String, Codable, CaseIterable, Sendable, Equatable {
    case sendNotification = "SEND_NOTIFICATION"
    case safeUnmountDrive = "SAFE_UNMOUNT_DRIVE"
    case safeEjectDrive = "SAFE_EJECT_DRIVE"
    case remountReadOnly = "REMOUNT_READ_ONLY"
    case startTimeMachineBackup = "START_TIME_MACHINE"
    case thinApfsSnapshots = "THIN_APFS_SNAPSHOTS"
    case runVolumeVerification = "RUN_VOLUME_VERIFY"
    case runQuickSurfaceScan = "RUN_QUICK_SURFACE_SCAN"
    case exportHtmlReport = "EXPORT_HTML_REPORT"
    case captureTopIoProcesses = "CAPTURE_TOP_IO_PROCS"
    case throttleTopIoProcess = "THROTTLE_TOP_IO_PROC"
    case preSleepShield = "PRE_SLEEP_SHIELD"
    case runMacShortcut = "RUN_MAC_SHORTCUT"
    case runCustomScript = "RUN_CUSTOM_SCRIPT"

    var displayName: String {
        switch self {
        case .sendNotification: return "Send Multi-Channel Alert (Desktop + Telegram + Webhook)"
        case .safeUnmountDrive: return "Safe Unmount Volume (External Only)"
        case .safeEjectDrive: return "Safe Eject Physical Drive (External Only)"
        case .remountReadOnly: return "Remount Volume Read-Only (Freeze Writes)"
        case .startTimeMachineBackup: return "Start Time Machine Auto-Backup (tmutil)"
        case .thinApfsSnapshots: return "Thin Local APFS Snapshots (Free up to 10 GB)"
        case .runVolumeVerification: return "Run File System Verification (diskutil)"
        case .runQuickSurfaceScan: return "Run Quick Surface Read Scan (F_NOCACHE)"
        case .exportHtmlReport: return "Export Standalone HTML RMA Report"
        case .captureTopIoProcesses: return "Capture & Log Top Disk I/O Processes"
        case .throttleTopIoProcess: return "Throttle Top Disk I/O Process to Background Tier"
        case .preSleepShield: return "Pre-Sleep External Drive Shield (Safe Auto-Unmount)"
        case .runMacShortcut: return "Run macOS Shortcut"
        case .runCustomScript: return "Execute Custom Sandboxed Script"
        }
    }

    var shortBadgeTitle: String {
        switch self {
        case .sendNotification: return "Multi-Channel Alert"
        case .safeUnmountDrive: return "Safe Unmount"
        case .safeEjectDrive: return "Safe Eject"
        case .remountReadOnly: return "Freeze Read-Only"
        case .startTimeMachineBackup: return "Time Machine Backup"
        case .thinApfsSnapshots: return "Thin APFS Snapshots"
        case .runVolumeVerification: return "Verify Volume"
        case .runQuickSurfaceScan: return "Quick Surface Scan"
        case .exportHtmlReport: return "Export HTML Report"
        case .captureTopIoProcesses: return "Capture Top I/O PIDs"
        case .throttleTopIoProcess: return "Throttle Top I/O"
        case .preSleepShield: return "Pre-Sleep Shield"
        case .runMacShortcut: return "macOS Shortcut"
        case .runCustomScript: return "Custom Script"
        }
    }

    var requiresParameter: Bool {
        switch self {
        case .runMacShortcut, .runCustomScript:
            return true
        default:
            return false
        }
    }

    var isMutatingMountAction: Bool {
        switch self {
        case .safeUnmountDrive, .safeEjectDrive, .remountReadOnly, .preSleepShield:
            return true
        default:
            return false
        }
    }
}

/// Declarative "When [Trigger] on [Scope] for [Polls] -> Do [Action]" automation rule.
struct ActionRule: Codable, Identifiable, Sendable, Equatable {
    var id: String
    var name: String
    var isEnabled: Bool
    var scope: ActionDriveScope
    var specificTargetFilter: String
    var triggerMetric: ActionTriggerMetric
    var conditionOperator: ActionConditionOperator
    var thresholdValue: Double
    var targetIssueCode: String
    var requiredConsecutivePolls: Int
    var cooldownSeconds: TimeInterval
    var actionType: ActionExecutionType
    var actionParameter: String
    var dryRunOnly: Bool

    init(
        id: String = UUID().uuidString,
        name: String,
        isEnabled: Bool = true,
        scope: ActionDriveScope = .allDrives,
        specificTargetFilter: String = "",
        triggerMetric: ActionTriggerMetric = .issueCode,
        conditionOperator: ActionConditionOperator = .greaterThanOrEqual,
        thresholdValue: Double = 68.0,
        targetIssueCode: String = "TEMP_CRITICAL",
        requiredConsecutivePolls: Int = 1,
        cooldownSeconds: TimeInterval = 1800.0,
        actionType: ActionExecutionType = .sendNotification,
        actionParameter: String = "",
        dryRunOnly: Bool = false
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.scope = scope
        self.specificTargetFilter = specificTargetFilter
        self.triggerMetric = triggerMetric
        self.conditionOperator = conditionOperator
        self.thresholdValue = thresholdValue
        self.targetIssueCode = targetIssueCode
        self.requiredConsecutivePolls = max(1, min(requiredConsecutivePolls, 20))
        self.cooldownSeconds = max(60.0, cooldownSeconds)
        self.actionType = actionType
        self.actionParameter = actionParameter
        self.dryRunOnly = dryRunOnly
    }

    /// Human-readable summary of the trigger condition (e.g. "Drive Temp >= 68°C" or "Issue == MEDIA_ERRORS").
    var conditionSummary: String {
        switch triggerMetric {
        case .issueCode:
            return "Issue [\(targetIssueCode.isEmpty ? "ANY" : targetIssueCode)]"
        case .severityTransition:
            return "Severity -> \(targetIssueCode.isEmpty ? "CRITICAL" : targetIssueCode)"
        case .systemWillSleep:
            return "On macOS System Sleep Notification"
        default:
            let valStr: String
            if thresholdValue.truncatingRemainder(dividingBy: 1.0) == 0 {
                valStr = String(format: "%.0f", thresholdValue)
            } else {
                valStr = String(format: "%.1f", thresholdValue)
            }
            return "\(triggerMetric.displayName) \(conditionOperator.rawValue) \(valStr)\(triggerMetric.unitSuffix)"
        }
    }

    /// Built-in curated starter automation templates.
    /// Destructive/unmount presets default to `isEnabled = false` so users opt in explicitly.
    static var defaultStarterRules: [ActionRule] {
        [
            ActionRule(
                id: "preset-thermal-cutoff-external",
                name: "Thermal Cutoff Shield (External SSD)",
                isEnabled: false,
                scope: .externalOnly,
                triggerMetric: .temperatureCelsius,
                conditionOperator: .greaterThanOrEqual,
                thresholdValue: 68.0,
                targetIssueCode: "TEMP_CRITICAL",
                requiredConsecutivePolls: 2,
                cooldownSeconds: 1800.0,
                actionType: .safeUnmountDrive,
                actionParameter: "",
                dryRunOnly: false
            ),
            ActionRule(
                id: "preset-media-error-rma-freeze",
                name: "Media Corruption RMA Snapshot & Alert",
                isEnabled: true,
                scope: .allDrives,
                triggerMetric: .issueCode,
                conditionOperator: .greaterThanOrEqual,
                thresholdValue: 1.0,
                targetIssueCode: "MEDIA_ERRORS",
                requiredConsecutivePolls: 1,
                cooldownSeconds: 3600.0,
                actionType: .exportHtmlReport,
                actionParameter: "",
                dryRunOnly: false
            ),
            ActionRule(
                id: "preset-io-latency-culprit-capture",
                name: "High Write Latency I/O Culprit Capture",
                isEnabled: true,
                scope: .allDrives,
                triggerMetric: .avgWriteLatencyMs,
                conditionOperator: .greaterThanOrEqual,
                thresholdValue: 150.0,
                targetIssueCode: "IO_LATENCY_CRITICAL",
                requiredConsecutivePolls: 2,
                cooldownSeconds: 900.0,
                actionType: .captureTopIoProcesses,
                actionParameter: "",
                dryRunOnly: false
            ),
            ActionRule(
                id: "preset-low-space-apfs-thin",
                name: "Critical Low Space APFS Snapshot Thinning",
                isEnabled: false,
                scope: .allDrives,
                triggerMetric: .issueCode,
                conditionOperator: .lessThanOrEqual,
                thresholdValue: 15.0,
                targetIssueCode: "DISK_SPACE_CRITICAL",
                requiredConsecutivePolls: 2,
                cooldownSeconds: 3600.0,
                actionType: .thinApfsSnapshots,
                actionParameter: "",
                dryRunOnly: false
            ),
            ActionRule(
                id: "preset-endurance-tm-backup",
                name: "Endurance Warning Emergency Time Machine Backup",
                isEnabled: false,
                scope: .allDrives,
                triggerMetric: .issueCode,
                conditionOperator: .lessThanOrEqual,
                thresholdValue: 25.0,
                targetIssueCode: "SPARE_WARNING",
                requiredConsecutivePolls: 1,
                cooldownSeconds: 14400.0,
                actionType: .startTimeMachineBackup,
                actionParameter: "",
                dryRunOnly: false
            )
        ]
    }

    static var builtInPresets: [ActionRule] { defaultStarterRules }
}

/// Outcome status of an executed or simulated `ActionRule`.
enum ActionExecutionStatus: String, Codable, Sendable, Equatable {
    case succeeded = "SUCCESS"
    case dryRun = "DRY_RUN"
    case blockedBySafetyGuard = "SAFETY_BLOCKED"
    case failed = "FAILED"
}

/// Persistent audit record of an `ActionRule` execution or dry-run simulation.
struct ActionExecutionRecord: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let timestamp: TimeInterval
    let formattedTime: String
    let ruleId: String
    let ruleName: String
    let driveKey: String
    let driveDisplayName: String
    let actionType: ActionExecutionType
    let status: ActionExecutionStatus
    let triggerReason: String
    let outputDetail: String
}
