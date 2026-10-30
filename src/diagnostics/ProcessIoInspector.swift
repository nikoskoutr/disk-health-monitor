// ============================================================================
// File: ProcessIoInspector.swift
// Module: Layer 3 (Diagnostics & Process I/O Telemetry)
// Purpose: Ranks active Darwin processes by disk read/write byte deltas using
//          libproc (DiskSampleProcessIoMetrics) with zero external dependencies.
// Concurrency: Thread-safe via NSLock (leaf lock).
// ============================================================================

import Foundation
import Darwin

/// Ranked process disk I/O entry showing interval or lifetime bytes and throughput.
struct ProcessIoCulprit: Codable, Sendable, Equatable, Identifiable {
    var id: Int32 { pid }
    let pid: Int32
    let processName: String
    let deltaBytesRead: UInt64
    let deltaBytesWritten: UInt64
    let totalBytesRead: UInt64
    let totalBytesWritten: UInt64
    let readMBps: Double
    let writeMBps: Double

    var combinedDeltaBytes: UInt64 {
        deltaBytesRead &+ deltaBytesWritten
    }

    var combinedMBps: Double {
        readMBps + writeMBps
    }

    var formattedSummary: String {
        if combinedMBps >= 0.05 {
            return String(
                format: "%@ (PID %d): R %.2f MB/s, W %.2f MB/s (Total W: %@)",
                processName,
                pid,
                readMBps,
                writeMBps,
                formatBytes(totalBytesWritten)
            )
        }
        return String(
            format: "%@ (PID %d): Cumulative R %@, W %@",
            processName,
            pid,
            formatBytes(totalBytesRead),
            formatBytes(totalBytesWritten)
        )
    }
}

/// Samples and ranks top disk I/O processes via Darwin `<libproc.h>`.
final class ProcessIoInspector: @unchecked Sendable {
    static let shared = ProcessIoInspector()

    struct RawSample: Sendable, Equatable {
        let pid: Int32
        let processName: String
        let bytesRead: UInt64
        let bytesWritten: UInt64
    }

    private let lock = NSLock()
    private var lastSampleByPid: [Int32: RawSample] = [:]
    private var lastSampleTimestamp: TimeInterval = 0

    /// Captures a raw snapshot of all accessible processes with disk I/O via C11 bridge.
    func captureRawSamples(maxCount: Int = 512) -> [Int32: RawSample] {
        let cap = max(16, min(maxCount, 2048))
        var rawArray = [DiskProcessIoMetric](repeating: DiskProcessIoMetric(), count: cap)
        let count = DiskSampleProcessIoMetrics(&rawArray, Int32(cap))
        guard count > 0 else { return [:] }

        var dict: [Int32: RawSample] = [:]
        dict.reserveCapacity(Int(count))
        for i in 0..<Int(count) {
            let item = rawArray[i]
            let name = cStringToSwift(item.processName)
            dict[item.pid] = RawSample(
                pid: item.pid,
                processName: name.isEmpty ? "pid-\(item.pid)" : name,
                bytesRead: item.diskBytesRead,
                bytesWritten: item.diskBytesWritten
            )
        }
        return dict
    }

    /// Pure deterministic calculator comparing two process I/O snapshots over `elapsedSeconds`.
    static func computeCulprits(
        previous: [Int32: RawSample],
        current: [Int32: RawSample],
        elapsedSeconds: TimeInterval,
        topN: Int = 5
    ) -> [ProcessIoCulprit] {
        let safeDt = max(0.05, elapsedSeconds)
        var results: [ProcessIoCulprit] = []
        results.reserveCapacity(current.count)

        for (pid, cur) in current {
            var dRead: UInt64 = 0
            var dWrite: UInt64 = 0
            if let prev = previous[pid], prev.processName == cur.processName {
                if cur.bytesRead >= prev.bytesRead {
                    dRead = cur.bytesRead - prev.bytesRead
                }
                if cur.bytesWritten >= prev.bytesWritten {
                    dWrite = cur.bytesWritten - prev.bytesWritten
                }
            }
            let rMBps = Double(dRead) / (1_000_000.0 * safeDt)
            let wMBps = Double(dWrite) / (1_000_000.0 * safeDt)
            results.append(ProcessIoCulprit(
                pid: pid,
                processName: cur.processName,
                deltaBytesRead: dRead,
                deltaBytesWritten: dWrite,
                totalBytesRead: cur.bytesRead,
                totalBytesWritten: cur.bytesWritten,
                readMBps: rMBps,
                writeMBps: wMBps
            ))
        }

        // Sort primarily by active interval delta I/O, falling back to cumulative lifetime I/O
        results.sort { a, b in
            if a.combinedDeltaBytes != b.combinedDeltaBytes {
                return a.combinedDeltaBytes > b.combinedDeltaBytes
            }
            let aTotal = a.totalBytesRead &+ a.totalBytesWritten
            let bTotal = b.totalBytesRead &+ b.totalBytesWritten
            if aTotal != bTotal {
                return aTotal > bTotal
            }
            return a.pid < b.pid
        }

        return Array(results.prefix(max(1, topN)))
    }

    /// Updates the rolling poll baseline and returns the top N processes since the previous poll.
    func pollAndRankCulprits(nowTs: TimeInterval = Date().timeIntervalSince1970, topN: Int = 5) -> [ProcessIoCulprit] {
        let current = captureRawSamples()
        lock.lock()
        let prev = lastSampleByPid
        let prevTs = lastSampleTimestamp
        lastSampleByPid = current
        lastSampleTimestamp = nowTs
        lock.unlock()

        let dt = prevTs > 0 && nowTs > prevTs ? (nowTs - prevTs) : 1.0
        return Self.computeCulprits(previous: prev, current: current, elapsedSeconds: dt, topN: topN)
    }

    /// Performs an on-demand two-point window sample (e.g. 350ms) to identify live I/O culprits immediately.
    func sampleActiveCulpritsWindow(durationSec: TimeInterval = 0.35, topN: Int = 5) -> [ProcessIoCulprit] {
        let first = captureRawSamples()
        let start = Date().timeIntervalSince1970
        let clampedSleep = max(0.05, min(durationSec, 2.0))
        Thread.sleep(forTimeInterval: clampedSleep)
        let second = captureRawSamples()
        let end = Date().timeIntervalSince1970

        lock.lock()
        lastSampleByPid = second
        lastSampleTimestamp = end
        lock.unlock()

        return Self.computeCulprits(
            previous: first,
            current: second,
            elapsedSeconds: max(0.05, end - start),
            topN: topN
        )
    }

    /// Pinpoints and throttles the highest disk I/O process actively writing to `mountPath` (PROC-03).
    func throttleRunawayProcess(forMount mountPath: String) -> (throttled: Bool, culprit: ProcessIoCulprit?, message: String) {
        let trimmed = mountPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (trimmed as NSString).standardizingPath
        if trimmed.isEmpty || normalized == "/" || normalized.hasPrefix("/System") || normalized.hasPrefix("/private") {
            return (false, nil, "Throttling runaway processes on system volume '\(mountPath)' is prohibited for safety")
        }

        let blockers = OpenFileBlockerInspector.shared.inspectBlockers(mountPath: mountPath)
        guard !blockers.isEmpty else {
            return (false, nil, "No open file blockers detected on '\(mountPath)'")
        }

        let blockingPids = Set(blockers.map { $0.pid })
        let culprits = sampleActiveCulpritsWindow(durationSec: 0.35, topN: 16)
        guard let topCulprit = culprits.first(where: { blockingPids.contains($0.pid) }) else {
            return (false, nil, "No high-throughput process found among open file handles on '\(mountPath)'")
        }

        // Hard safety checks: never throttle protected system processes
        if topCulprit.pid <= 100 {
            return (false, topCulprit, "Process \(topCulprit.processName) (PID \(topCulprit.pid)) is a protected system process (PID <= 100)")
        }
        let exemptNames: Set<String> = [
            "kernel_task", "launchd", "WindowServer", "loginwindow", "Finder", "backupd", "fsck_apfs",
            "DiskHealthMonitor", "diskutil", "syslogd", "opendirectoryd"
        ]
        if exemptNames.contains(topCulprit.processName) {
            return (false, topCulprit, "Process \(topCulprit.processName) is exempted from throttling")
        }

        let res = DiskSetProcessBackgroundIoPriority(topCulprit.pid, true)
        if res == 0 {
            return (true, topCulprit, "Throttled \(topCulprit.processName) (PID \(topCulprit.pid)) to Darwin background I/O tier (writing \(String(format: "%.2f", topCulprit.writeMBps)) MB/s)")
        } else {
            return (false, topCulprit, "Failed to throttle \(topCulprit.processName) (PID \(topCulprit.pid)): errno \(-res)")
        }
    }
}
