// ============================================================================
// File: ApfsSnapshotService.swift
// Module: Layer 3 (Telemetry & Engine)
// Purpose: APFS local snapshot inventory and pruning service (APFS-02).
//          Enumerates hidden Time Machine APFS snapshots, calculates snapshot age,
//          and triggers safely throttled snapshot thinning to reclaim storage.
// Concurrency: Thread-safe; subprocesses executed via SubprocessRunner with watchdog.
// ============================================================================

import Foundation

public struct ApfsSnapshotInfo: Identifiable, Sendable, Codable {
    public var id: String { snapshotName }
    public let snapshotName: String
    public let mountPath: String
    public let timestampString: String
    public let ageSeconds: TimeInterval

    public var formattedAge: String {
        let hours = Int(ageSeconds / 3600.0)
        if hours < 24 {
            return "\(max(1, hours))h ago"
        }
        let days = hours / 24
        return "\(days)d ago"
    }

    public init(snapshotName: String, mountPath: String, timestampString: String, ageSeconds: TimeInterval) {
        self.snapshotName = snapshotName
        self.mountPath = mountPath
        self.timestampString = timestampString
        self.ageSeconds = ageSeconds
    }
}

public final class ApfsSnapshotService {
    public static let shared = ApfsSnapshotService()

    private init() {}

    /// Lists all APFS local Time Machine snapshots on the target mount.
    public func listSnapshots(mountPath: String = "/") -> [ApfsSnapshotInfo] {
        let target = mountPath.isEmpty ? "/" : mountPath
        let result = SubprocessRunner.run(
            executable: "/usr/bin/tmutil",
            arguments: ["listlocalsnapshots", target],
            timeoutSeconds: 15.0
        )

        guard result.isSuccess else { return [] }

        var snapshots: [ApfsSnapshotInfo] = []
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"

        let lines = result.stdout.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // Typical format: com.apple.TimeMachine.2026-10-25-081432.local
            let prefix = "com.apple.TimeMachine."
            guard trimmed.contains(prefix) else { continue }

            var tsPart = trimmed
            if let range = tsPart.range(of: prefix) {
                tsPart = String(tsPart[range.upperBound...])
            }
            if let dotRange = tsPart.range(of: ".local") {
                tsPart = String(tsPart[..<dotRange.lowerBound])
            }

            var age: TimeInterval = 0
            if let date = formatter.date(from: tsPart) {
                age = max(0, now.timeIntervalSince(date))
            }

            snapshots.append(
                ApfsSnapshotInfo(
                    snapshotName: trimmed,
                    mountPath: target,
                    timestampString: tsPart,
                    ageSeconds: age
                )
            )
        }

        // Sort descending by age (oldest first for thinning candidates)
        return snapshots.sorted { $0.ageSeconds > $1.ageSeconds }
    }

    /// Thins local APFS snapshots to reclaim up to `targetPurgeBytes` (urgency 1-4).
    public func thinSnapshots(
        mountPath: String = "/",
        targetPurgeBytes: UInt64 = 20_000_000_000,
        urgency: Int = 4
    ) -> SubprocessResult {
        let target = mountPath.isEmpty ? "/" : mountPath
        let clampedUrgency = min(max(1, urgency), 4)

        return SubprocessRunner.run(
            executable: "/usr/bin/tmutil",
            arguments: [
                "thinlocalsnapshots",
                target,
                String(targetPurgeBytes),
                String(clampedUrgency)
            ],
            timeoutSeconds: 45.0
        )
    }
}
