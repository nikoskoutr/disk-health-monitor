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
    private var archiveHourlyByDriveKey: [String: [TelemetryHistoryPoint]] = [:]
    private var lastPruneAttemptByKey: [String: TimeInterval] = [:]
    private var customFilePath: String?

    var historyFilePath: String {
        customFilePath ?? ConfigManager.shared.historyFilePath
    }

    private var archiveDirectoryPath: String {
        if let customFilePath {
            return "\(customFilePath).archive"
        }
        return "\(ConfigManager.shared.configDir)/history"
    }

    private func sanitizeArchiveKey(_ key: String) -> String {
        key.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).inverted).joined(separator: "_")
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
        updateArchiveBucketLocked(forKey: key, point: point)

        if persistToDisk {
            saveLocked()
            appendArchiveRecordLocked(snapshot: snapshot, point: point)
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
        let nowTs = snapshot.timestamp
        lock.lock()
        let inMemorySeries = container.pointsByDriveKey[snapshot.driveKey] ?? []
        let archiveBuckets = loadArchiveHistoryLocked(for: snapshot.driveKey, nowTs: nowTs)
        lock.unlock()

        let earliestInMemoryTs = inMemorySeries.first?.timestamp ?? Double.greatestFiniteMagnitude
        let olderArchive = archiveBuckets.filter { $0.timestamp < earliestInMemoryTs }
        let series = olderArchive + inMemorySeries

        guard !series.isEmpty else { return .zero }

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

    private func updateArchiveBucketLocked(forKey key: String, point: TelemetryHistoryPoint) {
        guard var buckets = archiveHourlyByDriveKey[key] else { return }
        let bucketHour = Int64(point.timestamp / 3600.0)
        if let last = buckets.last, Int64(last.timestamp / 3600.0) == bucketHour {
            buckets[buckets.count - 1] = point
        } else {
            buckets.append(point)
        }
        archiveHourlyByDriveKey[key] = buckets
    }

    private func loadArchiveHistoryLocked(for driveKey: String, nowTs: TimeInterval) -> [TelemetryHistoryPoint] {
        if let cached = archiveHourlyByDriveKey[driveKey] {
            return cached
        }
        let sanitizedKey = sanitizeArchiveKey(driveKey)
        let filePath = "\(archiveDirectoryPath)/\(sanitizedKey).jsonl"
        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            archiveHourlyByDriveKey[driveKey] = []
            return []
        }

        let cutoffTs = nowTs - (90.0 * 86400.0)
        let decoder = JSONDecoder()
        var byHour: [Int64: TelemetryHistoryPoint] = [:]

        for line in content.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
                  let point = try? decoder.decode(TelemetryHistoryPoint.self, from: data),
                  point.timestamp >= cutoffTs else { continue }
            let bucket = Int64(point.timestamp / 3600.0)
            byHour[bucket] = point
        }

        let sorted = byHour.values.sorted { $0.timestamp < $1.timestamp }
        archiveHourlyByDriveKey[driveKey] = sorted
        return sorted
    }

    /// Appends a compact JSON record to the 90-day archive file `<historyDir>/<driveKey>.jsonl`.
    func appendArchiveRecord(snapshot: DiskHealthSnapshot) {
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
        lock.lock()
        defer { lock.unlock() }
        appendArchiveRecordLocked(snapshot: snapshot, point: point)
    }

    private func appendArchiveRecordLocked(snapshot: DiskHealthSnapshot, point: TelemetryHistoryPoint) {
        let sanitizedKey = sanitizeArchiveKey(snapshot.driveKey)
        let dir = archiveDirectoryPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700
        ])
        let filePath = "\(dir)/\(sanitizedKey).jsonl"

        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(point),
              let jsonStr = String(data: data, encoding: .utf8),
              let lineData = (jsonStr + "\n").data(using: .utf8) else { return }

        let fd = open(filePath, O_CREAT | O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd >= 0 {
            _ = fchmod(fd, 0o600)
            lineData.withUnsafeBytes { rawBuf in
                guard let base = rawBuf.baseAddress else { return }
                var written = 0
                while written < rawBuf.count {
                    let rc = write(fd, base.advanced(by: written), rawBuf.count - written)
                    if rc > 0 {
                        written += rc
                    } else if rc < 0 && errno == EINTR {
                        continue
                    } else {
                        break
                    }
                }
            }
            close(fd)
        }

        let lastPrune = lastPruneAttemptByKey[snapshot.driveKey] ?? 0
        if (snapshot.timestamp - lastPrune) >= 86400.0,
           let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
           let size = attrs[.size] as? UInt64,
           size > 512 * 1024 {
            lastPruneAttemptByKey[snapshot.driveKey] = snapshot.timestamp
            pruneArchiveFileIfNeeded(filePath: filePath, nowTs: snapshot.timestamp, minSizeBytes: 128 * 1024)
        }
    }

    /// Prunes JSONL archive entries older than 90 days and writes back atomically with 0600 permissions.
    func pruneArchiveFileIfNeeded(filePath: String, nowTs: TimeInterval, minSizeBytes: UInt64 = 128 * 1024) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
              let size = attrs[.size] as? UInt64, size > minSizeBytes else { return }

        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { return }
        let cutoffTs = nowTs - (90.0 * 86400.0)
        var keptLines: [String] = []
        let decoder = JSONDecoder()

        for line in content.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
            if let point = try? decoder.decode(TelemetryHistoryPoint.self, from: data) {
                if point.timestamp >= cutoffTs {
                    keptLines.append(trimmed)
                }
            }
        }

        let compacted = keptLines.joined(separator: "\n") + (keptLines.isEmpty ? "" : "\n")
        if let compactedData = compacted.data(using: .utf8) {
            _ = AtomicFileWriter.writeRestricted(data: compactedData, toPath: filePath, permissions: 0o600)
        }
    }

    /// Clears stored history for testing or user reset.
    func clearAll(persistToDisk: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        container = TelemetryHistoryContainer()
        archiveHourlyByDriveKey.removeAll()
        lastPruneAttemptByKey.removeAll()
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
