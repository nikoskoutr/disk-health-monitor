// ============================================================================
// File: ApfsSnapshotService.swift
// Module: Layer 3 (Telemetry & Engine)
// Purpose: APFS local snapshot inventory and pruning service (APFS-02).
//          Enumerates hidden Time Machine APFS snapshots, calculates snapshot age,
//          and triggers safely throttled snapshot thinning to reclaim storage.
// Concurrency: Thread-safe; subprocesses executed via SubprocessRunner with watchdog.
// ============================================================================

import Foundation
import Darwin

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

    /// Validates and normalizes target path ensuring it is an absolute path, has no traversal,
    /// and resolves to a valid mounted APFS filesystem.
    public func validatedApfsMountPoint(_ path: String) -> String? {
        let candidate = path.isEmpty ? "/" : path
        guard candidate.hasPrefix("/"), !candidate.contains("\0"), !candidate.contains("..") else { return nil }

        var fs = statfs()
        guard statfs(candidate, &fs) == 0 else { return nil }

        let fstype = withUnsafePointer(to: &fs.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) {
                String(cString: $0)
            }
        }
        let mountOn = withUnsafePointer(to: &fs.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }

        // Must resolve to an APFS filesystem
        guard fstype == "apfs" else { return nil }
        return mountOn
    }

    /// Lists all APFS local Time Machine snapshots on the target mount.
    public func listSnapshots(mountPath: String = "/") -> [ApfsSnapshotInfo] {
        guard let target = validatedApfsMountPoint(mountPath) else { return [] }
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
        guard let target = validatedApfsMountPoint(mountPath) else {
            return SubprocessResult(
                exitCode: 1,
                stdout: "",
                stderr: "Error: '\(mountPath)' is not a valid mounted APFS filesystem.",
                timedOut: false
            )
        }
        let clampedUrgency = min(max(1, urgency), 4)
        let clampedPurgeBytes = min(max(100_000_000, targetPurgeBytes), 500_000_000_000)

        return SubprocessRunner.run(
            executable: "/usr/bin/tmutil",
            arguments: [
                "thinlocalsnapshots",
                target,
                String(clampedPurgeBytes),
                String(clampedUrgency)
            ],
            timeoutSeconds: 45.0
        )
    }
}
