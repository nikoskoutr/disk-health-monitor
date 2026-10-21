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

public let kAppVersion = "2.3.0"
public let kAppBuildNumber = "6"

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
    var id: String { code }
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

struct DiskPersistentState: Codable, Sendable, Equatable {
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
        let slice: Slice<UnsafeRawBufferPointer>
        if let nullIndex = rawBuffer.firstIndex(of: 0) {
            slice = rawBuffer[..<nullIndex]
        } else {
            slice = rawBuffer[...]
        }
        return String(decoding: slice, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
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
