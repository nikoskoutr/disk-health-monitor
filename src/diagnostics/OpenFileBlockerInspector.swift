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

    public init(pid: Int32, processName: String, filePath: String, fd: Int32) {
        self.pid = pid
        self.processName = processName
        self.filePath = filePath
        self.fd = fd
    }
}

public final class OpenFileBlockerInspector {
    public static let shared = OpenFileBlockerInspector()

    private let lock = NSLock()

    private init() {}

    /// Lists active processes holding open file descriptors on the targeted volume mount.
    public func inspectBlockers(mountPath: String, maxCount: Int = 64) -> [OpenFileBlocker] {
        guard !mountPath.isEmpty else { return [] }

        lock.lock()
        defer { lock.unlock() }

        var cList = [DiskFileBlocker](repeating: DiskFileBlocker(), count: maxCount)
        let found = mountPath.withCString { cPath in
            DiskListOpenFileBlockers(cPath, &cList, Int32(maxCount))
        }

        guard found > 0 else { return [] }

        var results: [OpenFileBlocker] = []
        for i in 0..<Int(found) {
            let item = cList[i]
            let pName = cStringToSwift(item.processName)
            let fPath = cStringToSwift(item.filePath)

            results.append(
                OpenFileBlocker(
                    pid: item.pid,
                    processName: pName.isEmpty ? "pid-\(item.pid)" : pName,
                    filePath: fPath,
                    fd: item.fd
                )
            )
        }
        return results
    }

    /// Attempts a clean unmount, falling back to a forced unmount if requested.
    public func unmountVolume(mountPath: String, force: Bool = false) -> SubprocessResult {
        var args = ["unmount"]
        if force {
            args.append("force")
        }
        args.append(mountPath)

        return SubprocessRunner.run(
            executable: "/usr/sbin/diskutil",
            arguments: args,
            timeoutSeconds: 15.0
        )
    }
}
