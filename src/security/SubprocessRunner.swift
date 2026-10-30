// ============================================================================
// File: SubprocessRunner.swift
// Module: Layer 2 (Security & Process Management)
// Purpose: POSIX process group isolated subprocess executor (PROC-02).
//          Eliminates PID-recycling races and ensures complete grandchild process
//          termination via POSIX_SPAWN_SETPGROUP and kill(-pgid, SIGKILL).
// Concurrency: Thread-safe; stdout/stderr drained concurrently via background queues.
// ============================================================================

import Foundation
import Darwin

public struct SubprocessResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool

    public var isSuccess: Bool {
        return exitCode == 0 && !timedOut
    }
}

public enum SubprocessRunner {
    /// Executes a binary with isolated process group semantics and a hard watchdog timeout.
    ///
    /// - Parameters:
    ///   - executable: Absolute path to the binary (e.g. "/usr/sbin/diskutil", "/usr/bin/tmutil").
    ///   - arguments: Command line arguments array.
    ///   - environment: Optional environment dictionary; defaults to clean scrubbed environment if nil.
    ///   - timeoutSeconds: Maximum execution duration before entire process group is killed.
    /// - Returns: SubprocessResult containing exit code, stdout, stderr, and timeout flag.
    public static func run(
        executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        timeoutSeconds: TimeInterval = 30.0
    ) -> SubprocessResult {
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]

        guard pipe(&outPipe) == 0 else {
            return SubprocessResult(exitCode: -1, stdout: "", stderr: "Failed to create stdout pipe: errno \(errno)", timedOut: false)
        }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0]); close(outPipe[1])
            return SubprocessResult(exitCode: -1, stdout: "", stderr: "Failed to create stderr pipe: errno \(errno)", timedOut: false)
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, outPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, errPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, outPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, outPipe[1])
        posix_spawn_file_actions_addclose(&fileActions, errPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, errPipe[1])

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        // Isolate child into its own process group (pgid == childPid)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)

        let argvStrings = [executable] + arguments
        let cArgs = argvStrings.map { strdup($0) } + [nil]
        let defaultCleanEnv = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8"
        ]
        let envStrings = (environment ?? defaultCleanEnv).map { "\($0.key)=\($0.value)" }
        let cEnv = envStrings.map { strdup($0) } + [nil]

        defer {
            cArgs.forEach { if let p = $0 { free(p) } }
            cEnv.forEach { if let p = $0 { free(p) } }
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attr)
        }

        var pid: pid_t = 0
        let spawnErr = posix_spawn(&pid, executable, &fileActions, &attr, cArgs, cEnv)
        close(outPipe[1])
        close(errPipe[1])

        guard spawnErr == 0, pid > 0 else {
            close(outPipe[0])
            close(errPipe[0])
            return SubprocessResult(
                exitCode: -1,
                stdout: "",
                stderr: "posix_spawn failed for \(executable): errno \(spawnErr)",
                timedOut: false
            )
        }

        // Drain stdout/stderr concurrently BEFORE waitpid to prevent 64KB pipe buffer deadlock
        var outData = Data()
        var errData = Data()
        let drainGroup = DispatchGroup()

        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            outData = Self.drainFd(outPipe[0])
            close(outPipe[0])
            drainGroup.leave()
        }

        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            errData = Self.drainFd(errPipe[0])
            close(errPipe[0])
            drainGroup.leave()
        }

        let stateLock = NSLock()
        var timedOut = false
        var processReaped = false

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + timeoutSeconds)
        timer.setEventHandler {
            stateLock.lock()
            guard !processReaped else {
                stateLock.unlock()
                return
            }
            timedOut = true
            stateLock.unlock()

            // Signal entire process group (-pid)
            kill(-pid, SIGTERM)
            usleep(200_000)

            stateLock.lock()
            if !processReaped {
                kill(-pid, SIGKILL)
            }
            stateLock.unlock()
        }
        timer.resume()

        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}

        stateLock.lock()
        processReaped = true
        let didTimeout = timedOut
        stateLock.unlock()

        timer.cancel()
        drainGroup.wait()

        let exitCode: Int32
        if didTimeout {
            exitCode = -9
        } else if (status & 0x7f) == 0 {
            exitCode = (status >> 8) & 0xff
        } else {
            exitCode = -1
        }

        return SubprocessResult(
            exitCode: exitCode,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }

    private static func drainFd(_ fd: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                data.append(buffer, count: n)
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        return data
    }
}
