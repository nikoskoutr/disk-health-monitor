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
