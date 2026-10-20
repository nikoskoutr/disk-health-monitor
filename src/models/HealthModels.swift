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

public let kAppVersion = "2.1.0"
public let kAppBuildNumber = "3"

// MARK: - Data Models

enum HealthSeverity: String, Codable {
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

struct HealthIssue: Codable, Identifiable {
    var id: String { code }
    let code: String
    let severity: HealthSeverity
    let title: String
    let detail: String
}

struct DriveBaselineState: Codable {
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
    }
}

struct DiskPersistentState: Codable {
    var monitoredTarget: String = ""
    var drives: [String: DriveBaselineState] = [:]
    var lastAlertTimestampByCode: [String: TimeInterval] = [:]
    var lastOverallSeverity: String = HealthSeverity.healthy.rawValue
    var dailySummaryEnabled: Bool = true
    var lastDailySummaryDate: String = ""

    init() {}

    private enum CodingKeys: String, CodingKey {
        case monitoredTarget, drives, lastAlertTimestampByCode
        case lastOverallSeverity, dailySummaryEnabled, lastDailySummaryDate
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

struct DiskHealthSnapshot: Codable {
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
    let peakTemperatureCelsius: Int
    let availableSpare: UInt8
    let availableSpareThreshold: UInt8
    let percentageUsed: UInt8
    let lifeRemainingPercent: Int
    let totalTerabytesRead: Double
    let totalTerabytesWritten: Double
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
    return withUnsafePointer(to: &copy) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { cStr in
            String(cString: cStr).trimmingCharacters(in: .whitespacesAndNewlines)
        }
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
