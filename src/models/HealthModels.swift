// ============================================================================
// File: HealthModels.swift
// Module: Layer 2 (Infrastructure & Models)
// Purpose: Core domain data structures, health snapshots, fleet aggregations,
//          severity classifications, and thread-safe POSIX formatters.
// Concurrency: Pure Sendable value types and synchronized formatters.
// ============================================================================

import Foundation

// MARK: - Application Version & Architecture Information

#if arch(arm64)
public let kAppArchitecture = "arm64 (Apple Silicon)"
public let kAppArchShort = "arm64"
#elseif arch(x86_64)
public let kAppArchitecture = "x86_64 (Intel)"
public let kAppArchShort = "x86_64"
#else
public let kAppArchitecture = "unknown"
public let kAppArchShort = "unknown"
#endif

public let kAppVersion = "2.8.0"
public let kAppBuildNumber = "11"

// MARK: - Data Models

enum HealthSeverity: String, Codable, Sendable, Equatable {
    case healthy = "HEALTHY"
    case warning = "WARNING"
    case critical = "CRITICAL"

    var emoji: String {
        switch self {
        case .healthy: return "🟢"
        case .warning: return "🟡"
        case .critical: return "🔴"
        }
    }

    var rank: Int {
        switch self {
        case .healthy: return 0
        case .warning: return 1
        case .critical: return 2
        }
    }
}

struct HealthIssue: Codable, Identifiable, Sendable, Equatable {
    var id: String { "\(code):\(detail)" }
    let code: String
    let severity: HealthSeverity
    let title: String
    let detail: String
}

struct DriveBaselineState: Codable, Sendable, Equatable {
    var bsdName: String = ""
    var serialNumber: String = ""
    var baselineUnsafeShutdowns: UInt64? = nil
    var baselineMediaErrors: UInt64? = nil
    var baselineErrorLogEntries: UInt64? = nil
    var baselineIoReadErrors: UInt64? = nil
    var baselineIoWriteErrors: UInt64? = nil
    var baselineIoReadRetries: UInt64? = nil
    var baselineIoWriteRetries: UInt64? = nil
    var peakTemperatureCelsius: Int = 0
    var lastVerifyTimestamp: TimeInterval = 0
    var lastVerifyResult: String = "Not run yet"
    var lastVerifyOk: Bool = true
    var lastOverallSeverity: String = HealthSeverity.healthy.rawValue
    var consecutiveUnhealthyPolls: Int = 0
    var consecutiveHealthyPolls: Int = 0
    var lastNotifiedSeverity: String = HealthSeverity.healthy.rawValue
    var lastRecoveryTimestamp: TimeInterval = 0
    var wasWritable: Bool? = nil

    init(bsdName: String = "", serialNumber: String = "") {
        self.bsdName = bsdName
        self.serialNumber = serialNumber
    }

    private enum CodingKeys: String, CodingKey {
        case bsdName, serialNumber
        case baselineUnsafeShutdowns, baselineMediaErrors, baselineErrorLogEntries
        case baselineIoReadErrors, baselineIoWriteErrors
        case baselineIoReadRetries, baselineIoWriteRetries
        case peakTemperatureCelsius, lastVerifyTimestamp, lastVerifyResult, lastVerifyOk
        case lastOverallSeverity
        case consecutiveUnhealthyPolls, consecutiveHealthyPolls, lastNotifiedSeverity
        case lastRecoveryTimestamp, wasWritable
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let def = DriveBaselineState()
        bsdName = try c.decodeIfPresent(String.self, forKey: .bsdName) ?? def.bsdName
        serialNumber = try c.decodeIfPresent(String.self, forKey: .serialNumber) ?? def.serialNumber
        baselineUnsafeShutdowns = try c.decodeIfPresent(UInt64.self, forKey: .baselineUnsafeShutdowns)
        baselineMediaErrors = try c.decodeIfPresent(UInt64.self, forKey: .baselineMediaErrors)
        baselineErrorLogEntries = try c.decodeIfPresent(UInt64.self, forKey: .baselineErrorLogEntries)
        baselineIoReadErrors = try c.decodeIfPresent(UInt64.self, forKey: .baselineIoReadErrors)
        baselineIoWriteErrors = try c.decodeIfPresent(UInt64.self, forKey: .baselineIoWriteErrors)
        baselineIoReadRetries = try c.decodeIfPresent(UInt64.self, forKey: .baselineIoReadRetries)
        baselineIoWriteRetries = try c.decodeIfPresent(UInt64.self, forKey: .baselineIoWriteRetries)
        peakTemperatureCelsius = try c.decodeIfPresent(Int.self, forKey: .peakTemperatureCelsius) ?? def.peakTemperatureCelsius
        lastVerifyTimestamp = try c.decodeIfPresent(TimeInterval.self, forKey: .lastVerifyTimestamp) ?? def.lastVerifyTimestamp
        lastVerifyResult = try c.decodeIfPresent(String.self, forKey: .lastVerifyResult) ?? def.lastVerifyResult
        lastVerifyOk = try c.decodeIfPresent(Bool.self, forKey: .lastVerifyOk) ?? def.lastVerifyOk
        lastOverallSeverity = try c.decodeIfPresent(String.self, forKey: .lastOverallSeverity) ?? def.lastOverallSeverity
        consecutiveUnhealthyPolls = try c.decodeIfPresent(Int.self, forKey: .consecutiveUnhealthyPolls) ?? def.consecutiveUnhealthyPolls
        consecutiveHealthyPolls = try c.decodeIfPresent(Int.self, forKey: .consecutiveHealthyPolls) ?? def.consecutiveHealthyPolls
        lastNotifiedSeverity = try c.decodeIfPresent(String.self, forKey: .lastNotifiedSeverity) ?? def.lastNotifiedSeverity
        lastRecoveryTimestamp = try c.decodeIfPresent(TimeInterval.self, forKey: .lastRecoveryTimestamp) ?? def.lastRecoveryTimestamp
        wasWritable = try c.decodeIfPresent(Bool.self, forKey: .wasWritable) ?? def.wasWritable
    }
}

struct DiskPersistentState: Codable, Sendable, Equatable {
    var monitoredTarget: String = ""
    var drives: [String: DriveBaselineState] = [:]
    var lastAlertTimestampByCode: [String: TimeInterval] = [:]
    var lastOverallSeverity: String = HealthSeverity.healthy.rawValue
    var dailySummaryEnabled: Bool = true
    var lastDailySummaryDate: String = ""
    var lastRuleFiredTimestampById: [String: TimeInterval] = [:]
    var consecutiveRuleMatchPollsById: [String: Int] = [:]
    var recentActionExecutions: [ActionExecutionRecord] = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case monitoredTarget, drives, lastAlertTimestampByCode
        case lastOverallSeverity, dailySummaryEnabled, lastDailySummaryDate
        case lastRuleFiredTimestampById, consecutiveRuleMatchPollsById, recentActionExecutions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let def = DiskPersistentState()
        monitoredTarget = try c.decodeIfPresent(String.self, forKey: .monitoredTarget) ?? def.monitoredTarget
        drives = try c.decodeIfPresent([String: DriveBaselineState].self, forKey: .drives) ?? def.drives
        lastAlertTimestampByCode = try c.decodeIfPresent([String: TimeInterval].self, forKey: .lastAlertTimestampByCode) ?? def.lastAlertTimestampByCode
        lastOverallSeverity = try c.decodeIfPresent(String.self, forKey: .lastOverallSeverity) ?? def.lastOverallSeverity
        dailySummaryEnabled = try c.decodeIfPresent(Bool.self, forKey: .dailySummaryEnabled) ?? def.dailySummaryEnabled
        lastDailySummaryDate = try c.decodeIfPresent(String.self, forKey: .lastDailySummaryDate) ?? def.lastDailySummaryDate
        lastRuleFiredTimestampById = try c.decodeIfPresent([String: TimeInterval].self, forKey: .lastRuleFiredTimestampById) ?? def.lastRuleFiredTimestampById
        consecutiveRuleMatchPollsById = try c.decodeIfPresent([String: Int].self, forKey: .consecutiveRuleMatchPollsById) ?? def.consecutiveRuleMatchPollsById
        recentActionExecutions = try c.decodeIfPresent([ActionExecutionRecord].self, forKey: .recentActionExecutions) ?? def.recentActionExecutions
    }

    func getDriveState(key: String, bsdName: String = "", serial: String = "") -> DriveBaselineState {
        drives[key] ?? DriveBaselineState(bsdName: bsdName, serialNumber: serial)
    }

    mutating func updateDriveState(key: String, _ updater: (inout DriveBaselineState) -> Void) {
        var d = drives[key] ?? DriveBaselineState()
        updater(&d)
        drives[key] = d
    }
}

struct DiskHealthSnapshot: Codable, Sendable, Equatable {
    let timestamp: TimeInterval
    let formattedTime: String
    let formattedShortTime: String
    let overallSeverity: HealthSeverity
    let healthScore: Int
    let issues: [HealthIssue]

    // Hardware & Bus
    let hardwareFound: Bool
    let vendorName: String
    let productName: String
    let productRevision: String
    let bsdName: String
    let serialNumber: String
    let usbSerialNumber: String
    let interconnectType: String
    let protocolType: String
    let isInternal: Bool
    let isRemovable: Bool
    let linkSpeedBps: UInt64
    let linkSpeedFormatted: String

    // Mount & Capacity
    let isMounted: Bool
    let mountPoint: String
    let filesystemType: String
    let isReadOnly: Bool
    let totalBytes: UInt64
    let freeBytes: UInt64
    var purgeableBytes: UInt64 = 0
    let usedBytes: UInt64
    let usedPercent: Double
    let subpathsStatus: [String: Bool]

    // Active Canary
    let canaryOk: Bool
    let canaryLatencyMs: Double
    let canaryError: String

    // NVMe SMART
    let smartValid: Bool
    let criticalWarning: UInt8
    let temperatureCelsius: Int
    var temperatureKelvin: Int = 0
    let peakTemperatureCelsius: Int
    let availableSpare: UInt8
    let availableSpareThreshold: UInt8
    let percentageUsed: UInt8
    let lifeRemainingPercent: Int
    var dataUnitsRead: UInt64 = 0
    var dataUnitsWritten: UInt64 = 0
    let totalTerabytesRead: Double
    let totalTerabytesWritten: Double
    var hostReadCommands: UInt64 = 0
    var hostWriteCommands: UInt64 = 0
    var controllerBusyTime: UInt64 = 0
    let powerCycles: UInt64
    let powerOnHours: UInt64
    let unsafeShutdowns: UInt64
    let mediaErrors: UInt64
    let errorInfoLogEntries: UInt64

    // Block Driver Stats
    let statsValid: Bool
    let sessionBytesRead: UInt64
    let sessionBytesWritten: UInt64
    let operationsRead: UInt64
    let operationsWritten: UInt64
    let errorsRead: UInt64
    let errorsWritten: UInt64
    let retriesRead: UInt64
    let retriesWritten: UInt64
    let avgReadLatencyMs: Double
    let avgWriteLatencyMs: Double
    let readThroughputMBps: Double
    let writeThroughputMBps: Double

    // Volume Verification
    let lastVerifyResult: String
    let lastVerifyOk: Bool

    // Disambiguated Identity
    var customDriveKey: String? = nil

    // USB Bus Power & Interconnect Topology (v2.8.0+)
    var usbCurrentAvailableMa: UInt32 = 0
    var usbCurrentRequiredMa: UInt32 = 0
    var linkWidthLanes: UInt32 = 0

    // Computed SSD Endurance & Wear-Rate Projections
    var dailyTerabytesWritten: Double {
        guard smartValid, powerOnHours > 0, totalTerabytesWritten > 0 else { return 0.0 }
        let activeDays = max(1.0, Double(powerOnHours) / 24.0)
        return totalTerabytesWritten / activeDays
    }

    var estimatedRemainingLifeFormatted: String {
        guard smartValid else { return "N/A" }
        if percentageUsed >= 100 {
            return "Depleted (< 1% left)"
        }
        guard powerOnHours >= 24 else {
            return "Calibrating (< 24h POH)"
        }
        let activeDays = Double(powerOnHours) / 24.0
        if percentageUsed == 0 {
            return "> 10 Years (0% Wear)"
        }
        let daysPerPercent = activeDays / Double(percentageUsed)
        let remainingDays = daysPerPercent * Double(max(0, 100 - Int(percentageUsed)))
        if remainingDays >= 3650 {
            return "> 10 Years"
        } else if remainingDays >= 365 {
            return String(format: "~%.1f Years", remainingDays / 365.25)
        } else if remainingDays >= 30 {
            return String(format: "~%.0f Months", remainingDays / 30.44)
        } else {
            return String(format: "~%.0f Days", max(1.0, remainingDays))
        }
    }
}

// MARK: - Helpers & Formatting

func formatBytes(_ bytes: UInt64) -> String {
    let tb = Double(bytes) / 1_000_000_000_000.0
    if tb >= 1.0 {
        return String(format: "%.2f TB", tb)
    }
    let gb = Double(bytes) / 1_000_000_000.0
    if gb >= 1.0 {
        return String(format: "%.1f GB", gb)
    }
    let mb = Double(bytes) / 1_000_000.0
    return String(format: "%.1f MB", mb)
}

func formatLinkSpeed(_ bps: UInt64, interconnect: String) -> String {
    if bps >= 40_000_000_000 {
        return String(format: "%.0f Gbps (Thunderbolt 3/4)", Double(bps) / 1_000_000_000.0)
    } else if bps >= 20_000_000_000 {
        return String(format: "%.0f Gbps (USB4 / SuperSpeed+ 20G)", Double(bps) / 1_000_000_000.0)
    } else if bps >= 10_000_000_000 {
        return String(format: "%.0f Gbps (SuperSpeed+ 10G)", Double(bps) / 1_000_000_000.0)
    } else if bps >= 5_000_000_000 {
        return String(format: "%.0f Gbps (SuperSpeed 5G)", Double(bps) / 1_000_000_000.0)
    } else if bps >= 480_000_000 {
        return String(format: "%.0f Mbps (High-Speed USB 2.0)", Double(bps) / 1_000_000.0)
    } else if bps > 0 {
        return "\(bps) bps"
    }
    return interconnect.isEmpty ? "Direct / Internal" : interconnect
}

func cStringToSwift<T>(_ tuple: T) -> String {
    var copy = tuple
    return withUnsafeBytes(of: &copy) { rawBuffer in
        let endIdx = rawBuffer.firstIndex(of: 0) ?? rawBuffer.endIndex
        var start = rawBuffer.startIndex
        var end = endIdx
        while start < end {
            let b = rawBuffer[start]
            if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D { start += 1 } else { break }
        }
        while end > start {
            let b = rawBuffer[end - 1]
            if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D { end -= 1 } else { break }
        }
        guard start < end else { return "" }
        return String(decoding: rawBuffer[start..<end], as: UTF8.self)
    }
}

// POSIX locale formatters ensuring consistent, thread-safe formatting across any macOS system language/time setting
final class SynchronizedDateFormatter: DateFormatter, @unchecked Sendable {
    private let lock = NSLock()

    override func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return super.string(from: date)
    }

    override func date(from string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return super.date(from: string)
    }
}

let isoTimestampFormatter: SynchronizedDateFormatter = {
    let df = SynchronizedDateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return df
}()

let shortTimeFormatter: SynchronizedDateFormatter = {
    let df = SynchronizedDateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.dateFormat = "HH:mm:ss"
    return df
}()

let shortMonthDateFormatter: SynchronizedDateFormatter = {
    let df = SynchronizedDateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.dateFormat = "MMM d, HH:mm"
    return df
}()

// Enable DiskHardwareMetrics C struct to cross Swift concurrency boundaries safely
extension DiskHardwareMetrics: @unchecked Sendable {}

// MARK: - Multi-Disk Fleet Models & Snapshot Extensions

extension DiskHealthSnapshot: Identifiable {
    static func isPlaceholderSerial(_ serial: String) -> Bool {
        let s = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return true }
        let lower = s.lowercased()
        let placeholders: Set<String> = [
            "00000000",
            "000000000000",
            "0000000000000000",
            "0123456789abcdef",
            "1234567890",
            "none",
            "n/a",
            "na",
            "unknown",
            "generic",
            "default",
            "0"
        ]
        if placeholders.contains(lower) { return true }
        if lower.count >= 4 && Set(lower).count == 1 { return true }
        return false
    }

    var driveKey: String {
        if let custom = customDriveKey, !custom.isEmpty {
            return custom
        }
        if !serialNumber.isEmpty && !DiskHealthSnapshot.isPlaceholderSerial(serialNumber) {
            return serialNumber
        }
        if !serialNumber.isEmpty && !bsdName.isEmpty {
            return "\(serialNumber)#\(bsdName)"
        }
        if !bsdName.isEmpty { return bsdName }
        if !mountPoint.isEmpty { return mountPoint }
        return "\(vendorName)-\(productName)"
    }

    var id: String { driveKey }

    var displayLabel: String {
        let model = "\(vendorName) \(productName)".trimmingCharacters(in: .whitespaces)
        if !bsdName.isEmpty {
            return "\(model) (\(bsdName))"
        }
        return model
    }
}

struct MultiDiskHealthSnapshot: Codable, Sendable, Equatable {
    let timestamp: TimeInterval
    let formattedTime: String
    let formattedShortTime: String
    let overallSeverity: HealthSeverity
    let worstHealthScore: Int
    let averageHealthScore: Int
    let totalIssuesCount: Int
    let disks: [DiskHealthSnapshot]

    init(
        timestamp: TimeInterval,
        formattedTime: String,
        formattedShortTime: String,
        overallSeverity: HealthSeverity,
        worstHealthScore: Int,
        averageHealthScore: Int,
        totalIssuesCount: Int,
        disks: [DiskHealthSnapshot]
    ) {
        self.timestamp = timestamp
        self.formattedTime = formattedTime
        self.formattedShortTime = formattedShortTime
        self.overallSeverity = overallSeverity
        self.worstHealthScore = worstHealthScore
        self.averageHealthScore = averageHealthScore
        self.totalIssuesCount = totalIssuesCount
        self.disks = disks
    }

    var primarySnapshot: DiskHealthSnapshot? {
        disks.max(by: { a, b in
            if a.overallSeverity.rank != b.overallSeverity.rank {
                return a.overallSeverity.rank < b.overallSeverity.rank
            }
            if a.healthScore != b.healthScore {
                return a.healthScore > b.healthScore // Lower score is considered more degraded/worse
            }
            return a.driveKey < b.driveKey // Deterministic alphabetical tie-breaker
        }) ?? disks.first
    }
}

// ============================================================================
// MARK: - Declarative Rule-Based Automation Engine Models ("When X, Do Y")
// ============================================================================

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
        }
    }

    var unitSuffix: String {
        switch self {
        case .issueCode, .severityTransition: return ""
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
        case .issueCode, .severityTransition:
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
        case .safeUnmountDrive, .safeEjectDrive, .remountReadOnly:
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
