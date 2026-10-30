// ============================================================================
// File: TelemetryHistoryStore.swift
// Module: Layer 3 (Telemetry & Domain Engine)
// Purpose: Thread-safe historical telemetry ring buffer persisted to history.json
//          (0600) enabling rate-of-change automation rules and UI sparklines.
// Concurrency: Synchronized via NSLock (leaf lock).
// ============================================================================

import Foundation

/// Single time-series telemetry rollup point for a monitored physical drive.
struct TelemetryHistoryPoint: Codable, Sendable, Equatable, Identifiable {
    var id: TimeInterval { timestamp }
    let timestamp: TimeInterval
    let overallSeverity: HealthSeverity
    let healthScore: Int
    let temperatureCelsius: Int
    let freeBytes: UInt64
    let usedPercent: Double
    let totalTerabytesWritten: Double
    let avgReadLatencyMs: Double
    let avgWriteLatencyMs: Double
}

/// Computed rate-of-change metrics derived from a drive's historical ring buffer.
struct HistoryRateMetrics: Sendable, Equatable {
    let freeSpaceDropGBPerHour: Double
    let terabytesWrittenLast24h: Double

    static let zero = HistoryRateMetrics(freeSpaceDropGBPerHour: 0.0, terabytesWrittenLast24h: 0.0)
}

/// Rolling statistical telemetry forecasts and percentiles (HIST-01).
struct RollingForecastMetrics: Sendable, Equatable {
    let rolling7dTBPerDay: Double
    let rolling30dTBPerDay: Double
    let p95WriteLatencyMs: Double
    let p95TempCelsius: Int

    static let zero = RollingForecastMetrics(
        rolling7dTBPerDay: 0.0,
        rolling30dTBPerDay: 0.0,
        p95WriteLatencyMs: 0.0,
        p95TempCelsius: 0
    )
}

/// Top-level JSON container stored in `~/.config/disk-health-monitor/history.json`.
struct TelemetryHistoryContainer: Codable, Sendable, Equatable {
    var pointsByDriveKey: [String: [TelemetryHistoryPoint]] = [:]
}

/// Manages bounded time-series history per drive for rate-of-change rules and UI sparklines.
final class TelemetryHistoryStore: @unchecked Sendable {
    static let shared = TelemetryHistoryStore()

    static let maxPointsPerDrive: Int = 180
    static let defaultMinSampleIntervalSeconds: TimeInterval = 300.0 // 5 minutes

    private let lock = NSLock()
    private var container: TelemetryHistoryContainer
    private var customFilePath: String?

    var historyFilePath: String {
        customFilePath ?? ConfigManager.shared.historyFilePath
    }

    init(customFilePath: String? = nil) {
        self.customFilePath = customFilePath
        let path = customFilePath ?? ConfigManager.shared.historyFilePath
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let decoded = try? JSONDecoder().decode(TelemetryHistoryContainer.self, from: data) {
            self.container = decoded
        } else {
            self.container = TelemetryHistoryContainer()
        }
    }

    /// Appends a snapshot point if `minIntervalSeconds` has elapsed since the last sample,
    /// or if the drive's `overallSeverity` transitioned, or if `force == true`.
    @discardableResult
    func recordSnapshot(
        _ snapshot: DiskHealthSnapshot,
        minIntervalSeconds: TimeInterval = TelemetryHistoryStore.defaultMinSampleIntervalSeconds,
        force: Bool = false,
        persistToDisk: Bool = true
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let key = snapshot.driveKey
        var series = container.pointsByDriveKey[key] ?? []

        if !force, let last = series.last {
            let elapsed = snapshot.timestamp - last.timestamp
            let severityChanged = (last.overallSeverity != snapshot.overallSeverity)
            if elapsed >= 0 && elapsed < minIntervalSeconds && !severityChanged {
                return false
            }
        }

        let point = TelemetryHistoryPoint(
            timestamp: snapshot.timestamp,
            overallSeverity: snapshot.overallSeverity,
            healthScore: snapshot.healthScore,
            temperatureCelsius: snapshot.temperatureCelsius,
            freeBytes: snapshot.freeBytes,
            usedPercent: snapshot.usedPercent,
            totalTerabytesWritten: snapshot.totalTerabytesWritten,
            avgReadLatencyMs: snapshot.avgReadLatencyMs,
            avgWriteLatencyMs: snapshot.avgWriteLatencyMs
        )
        series.append(point)
        if series.count > Self.maxPointsPerDrive {
            series.removeFirst(series.count - Self.maxPointsPerDrive)
        }
        container.pointsByDriveKey[key] = series

        if persistToDisk {
            saveLocked()
            appendArchiveRecord(snapshot: snapshot)
        }
        return true
    }

    /// Returns a chronological array of historical telemetry points for a specific drive.
    func points(forDriveKey key: String) -> [TelemetryHistoryPoint] {
        lock.lock()
        defer { lock.unlock() }
        return container.pointsByDriveKey[key] ?? []
    }

    /// Computes rate-of-change metrics (GB/hour free space drop and 24h TBW burn) for a drive.
    func computeRateMetrics(for snapshot: DiskHealthSnapshot) -> HistoryRateMetrics {
        lock.lock()
        let series = container.pointsByDriveKey[snapshot.driveKey] ?? []
        lock.unlock()

        let nowTs = snapshot.timestamp

        // 1. Free Space Drop Rate (GB / hour) over the most recent 10m..6h window
        var freeSpaceDropGBPerHour = 0.0
        if snapshot.isMounted, let baselinePoint = series.first(where: { (nowTs - $0.timestamp) <= 6 * 3600 && (nowTs - $0.timestamp) >= 60 }) ?? series.first {
            let dtHours = (nowTs - baselinePoint.timestamp) / 3600.0
            if dtHours >= (1.0 / 60.0) && baselinePoint.freeBytes > snapshot.freeBytes {
                let droppedBytes = Double(baselinePoint.freeBytes - snapshot.freeBytes)
                let droppedGB = droppedBytes / 1_000_000_000.0
                freeSpaceDropGBPerHour = droppedGB / dtHours
            }
        }

        // 2. Terabytes Written in Last 24h (or extrapolated from active history / SMART lifetime)
        var tbw24h = snapshot.dailyTerabytesWritten
        if snapshot.smartValid, let oldestIn24h = series.first(where: { (nowTs - $0.timestamp) <= 24 * 3600 && (nowTs - $0.timestamp) >= 300 }) {
            let dtDays = (nowTs - oldestIn24h.timestamp) / 86400.0
            if dtDays > 0 && snapshot.totalTerabytesWritten >= oldestIn24h.totalTerabytesWritten {
                let deltaTB = snapshot.totalTerabytesWritten - oldestIn24h.totalTerabytesWritten
                let recentRate = deltaTB / dtDays
                if recentRate > tbw24h {
                    tbw24h = recentRate
                }
            }
        }

        return HistoryRateMetrics(
            freeSpaceDropGBPerHour: max(0.0, freeSpaceDropGBPerHour),
            terabytesWrittenLast24h: max(0.0, tbw24h)
        )
    }

    /// Computes rolling OLS linear regressions and p95 latency/temperature percentiles (HIST-01).
    func computeRollingForecasts(for snapshot: DiskHealthSnapshot) -> RollingForecastMetrics {
        lock.lock()
        let series = container.pointsByDriveKey[snapshot.driveKey] ?? []
        lock.unlock()

        guard !series.isEmpty else { return .zero }
        let nowTs = snapshot.timestamp

        // OLS regression helper over window: (timestamp, TBW)
        func computeOlsSlope(windowSeconds: TimeInterval) -> Double {
            let windowPoints = series.filter { (nowTs - $0.timestamp) <= windowSeconds }
            guard windowPoints.count >= 2 else { return snapshot.dailyTerabytesWritten }

            var sumX: Double = 0.0
            var sumY: Double = 0.0
            let t0 = windowPoints[0].timestamp

            let xyPairs = windowPoints.map { p -> (Double, Double) in
                let xDays = (p.timestamp - t0) / 86400.0
                let y = p.totalTerabytesWritten
                sumX += xDays
                sumY += y
                return (xDays, y)
            }

            let n = Double(xyPairs.count)
            let meanX = sumX / n
            let meanY = sumY / n

            var numerator: Double = 0.0
            var denominator: Double = 0.0

            for (x, y) in xyPairs {
                let dx = x - meanX
                let dy = y - meanY
                numerator += dx * dy
                denominator += dx * dx
            }

            if denominator > 0.000001 {
                let slope = numerator / denominator
                return max(0.0, slope)
            }

            // Fallback: simple delta
            if let first = windowPoints.first, let last = windowPoints.last, last.timestamp > first.timestamp {
                let dtDays = (last.timestamp - first.timestamp) / 86400.0
                return max(0.0, (last.totalTerabytesWritten - first.totalTerabytesWritten) / dtDays)
            }
            return snapshot.dailyTerabytesWritten
        }

        let rolling7d = computeOlsSlope(windowSeconds: 7 * 86400)
        let rolling30d = computeOlsSlope(windowSeconds: 30 * 86400)

        // Percentiles: p95 of write latency and temperature
        let writeLatencies = series.map(\.avgWriteLatencyMs).sorted()
        let p95Lat: Double = {
            guard !writeLatencies.isEmpty else { return snapshot.avgWriteLatencyMs }
            let idx = min(writeLatencies.count - 1, Int(Double(writeLatencies.count - 1) * 0.95))
            return writeLatencies[idx]
        }()

        let temps = series.map(\.temperatureCelsius).sorted()
        let p95Tmp: Int = {
            guard !temps.isEmpty else { return snapshot.temperatureCelsius }
            let idx = min(temps.count - 1, Int(Double(temps.count - 1) * 0.95))
            return temps[idx]
        }()

        return RollingForecastMetrics(
            rolling7dTBPerDay: rolling7d,
            rolling30dTBPerDay: rolling30d,
            p95WriteLatencyMs: p95Lat,
            p95TempCelsius: p95Tmp
        )
    }

    /// Appends a compact JSON record to the 90-day archive file ~/.config/disk-health-monitor/history/<driveKey>.jsonl.
    func appendArchiveRecord(snapshot: DiskHealthSnapshot) {
        let sanitizedKey = snapshot.driveKey.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).inverted).joined(separator: "_")
        let dir = "\(ConfigManager.shared.configDir)/history"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700
        ])
        let filePath = "\(dir)/\(sanitizedKey).jsonl"

        let point = TelemetryHistoryPoint(
            timestamp: snapshot.timestamp,
            overallSeverity: snapshot.overallSeverity,
            healthScore: snapshot.healthScore,
            temperatureCelsius: snapshot.temperatureCelsius,
            freeBytes: snapshot.freeBytes,
            usedPercent: snapshot.usedPercent,
            totalTerabytesWritten: snapshot.totalTerabytesWritten,
            avgReadLatencyMs: snapshot.avgReadLatencyMs,
            avgWriteLatencyMs: snapshot.avgWriteLatencyMs
        )

        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(point),
              let jsonStr = String(data: data, encoding: .utf8) else { return }

        let line = jsonStr + "\n"
        if let lineData = line.data(using: .utf8) {
            let url = URL(fileURLWithPath: filePath)
            if FileManager.default.fileExists(atPath: filePath) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: lineData)
                    try? handle.close()
                }
            } else {
                _ = AtomicFileWriter.writeRestricted(data: lineData, toPath: filePath, permissions: 0o600)
            }
        }
    }

    /// Clears stored history for testing or user reset.
    func clearAll(persistToDisk: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        container = TelemetryHistoryContainer()
        if persistToDisk {
            saveLocked()
        }
    }

    private func saveLocked() {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(container) else { return }
        _ = AtomicFileWriter.writeRestricted(data: data, toPath: historyFilePath, permissions: 0o600)
    }
}
