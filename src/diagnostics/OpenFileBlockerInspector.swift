// ============================================================================
// File: OpenFileBlockerInspector.swift
// Module: Layer 3 (Diagnostics & Telemetry)
// Purpose: Inspects open file handles and active processes preventing volume
//          unmount or safe eject (DA-01). Bridges Darwin libproc file descriptor
//          vnode path queries to provide exact blocking PID diagnostics.
// Concurrency: Thread-safe; queries executed under private leaf lock.
// ============================================================================

import Foundation

public struct OpenFileBlocker: Identifiable, Sendable {
    public var id: String { "\(pid):\(fd):\(filePath)" }
    public let pid: Int32
    public let processName: String
    public let filePath: String
    public let fd: Int32
    public let startTimeSec: UInt64
    public let isTerminatable: Bool

    public init(
        pid: Int32,
        processName: String,
        filePath: String,
        fd: Int32,
        startTimeSec: UInt64 = 0,
        isTerminatable: Bool = false
    ) {
        self.pid = pid
        self.processName = processName
        self.filePath = filePath
        self.fd = fd
        self.startTimeSec = startTimeSec
        self.isTerminatable = isTerminatable
    }
}

public final class OpenFileBlockerInspector {
    public static let shared = OpenFileBlockerInspector()

    private let lock = NSLock()

    private init() {}

    /// Lists active processes holding open file descriptors on the targeted volume mount.
    public func inspectBlockers(mountPath: String, maxCount: Int = 64) -> [OpenFileBlocker] {
        guard !mountPath.isEmpty else { return [] }

        let normMount = (mountPath as NSString).standardizingPath
        let isExternalVolume = normMount.hasPrefix("/Volumes/") && normMount.count > "/Volumes/".count

        lock.lock()
        defer { lock.unlock() }

        var cList = [DiskFileBlocker](repeating: DiskFileBlocker(), count: maxCount)
        let found = mountPath.withCString { cPath in
            DiskListOpenFileBlockers(cPath, &cList, Int32(maxCount))
        }

        guard found > 0 else { return [] }

        var results: [OpenFileBlocker] = []
        results.reserveCapacity(Int(found))
        for i in 0..<Int(found) {
            let item = cList[i]
            let pName = cStringToSwift(item.processName)
            let resolvedName = pName.isEmpty ? "pid-\(item.pid)" : pName
            let fPath = cStringToSwift(item.filePath)
            var isZombie = false
            let canTerm = isExternalVolume
                && item.startTimeSec > 0
                && !Self.protectedProcessNames.contains(resolvedName)
                && DiskVerifyBlockerForTermination(item.pid, item.startTimeSec, resolvedName, normMount, &isZombie)

            results.append(
                OpenFileBlocker(
                    pid: item.pid,
                    processName: resolvedName,
                    filePath: fPath,
                    fd: item.fd,
                    startTimeSec: item.startTimeSec,
                    isTerminatable: canTerm
                )
            )
        }
        return results
    }

    /// Attempts a clean unmount, falling back to a forced unmount if requested.
    public func unmountVolume(mountPath: String, force: Bool = false, timeoutSeconds: TimeInterval = 15.0) -> SubprocessResult {
        var args = ["unmount"]
        if force {
            args.append("force")
        }
        args.append(mountPath)

        return SubprocessRunner.run(
            executable: "/usr/sbin/diskutil",
            arguments: args,
            timeoutSeconds: timeoutSeconds
        )
    }

    private static let protectedProcessNames: Set<String> = [
        "launchd", "kernel_task", "WindowServer", "loginwindow", "Finder",
        "mds", "mds_stores", "fseventsd", "diskarbitrationd", "storagekitd",
        "fsck_apfs", "fsck_hfs", "CoreServicesUIAgent"
    ]

    private static func verifyBlockerLive(_ blocker: OpenFileBlocker, mountPath: String, isZombie: inout Bool) -> Bool {
        guard blocker.startTimeSec > 0 else { return false }
        return DiskVerifyBlockerForTermination(blocker.pid, blocker.startTimeSec, blocker.processName, mountPath, &isZombie)
    }

    /// Evaluates whether a process blocking unmount can be safely terminated.
    public static func canSafelyTerminate(blocker: OpenFileBlocker, mountPath: String) -> Bool {
        let normMount = (mountPath as NSString).standardizingPath
        guard normMount.hasPrefix("/Volumes/"), normMount.count > "/Volumes/".count else { return false }
        guard !protectedProcessNames.contains(blocker.processName) else { return false }
        var isZombie = false
        return verifyBlockerLive(blocker, mountPath: normMount, isZombie: &isZombie)
    }

    /// Terminates a process blocking volume unmount (SIGTERM with 200ms grace, escalating to SIGKILL).
    public func terminateBlocker(_ blocker: OpenFileBlocker, mountPath: String) -> (ok: Bool, message: String) {
        let normMount = (mountPath as NSString).standardizingPath
        guard Self.canSafelyTerminate(blocker: blocker, mountPath: normMount) else {
            return (false, "Refused by safety guard: '\(blocker.processName)' (PID \(blocker.pid)) is protected, owned by another user, or not on /Volumes/.")
        }
        if kill(blocker.pid, SIGTERM) != 0 && errno != ESRCH {
            return (false, "Failed to send SIGTERM to PID \(blocker.pid) (errno \(errno)).")
        }
        for _ in 0..<8 {
            usleep(25_000)
            var isZombie = false
            if !Self.verifyBlockerLive(blocker, mountPath: normMount, isZombie: &isZombie) {
                ConfigManager.shared.log("Terminated file blocker \(blocker.processName) (PID \(blocker.pid)) via SIGTERM.")
                return (true, "Terminated \(blocker.processName) (PID \(blocker.pid)).")
            }
        }
        // Re-verify identity (process name + start time + open FD) immediately before SIGKILL escalation to prevent PID-reuse sniping
        var isZombie = false
        if Self.verifyBlockerLive(blocker, mountPath: normMount, isZombie: &isZombie) {
            _ = kill(blocker.pid, SIGKILL)
            usleep(25_000)
        }
        let stillAlive = Self.verifyBlockerLive(blocker, mountPath: normMount, isZombie: &isZombie)
        ConfigManager.shared.log("Escalated SIGKILL to file blocker \(blocker.processName) (PID \(blocker.pid)): dead=\(!stillAlive).")
        return (!stillAlive, !stillAlive ? "Force-killed \(blocker.processName) (PID \(blocker.pid))." : "Process \(blocker.pid) did not exit.")
    }
}
