// ============================================================================
// File: VolumeVerifierService.swift
// Module: Layer 3 (Telemetry & Domain Engine)
// Purpose: Asynchronous filesystem verification invoking /usr/sbin/diskutil verifyVolume
//          with grandchild process tree termination (pkill -P) and exit classification.
// Concurrency: Executes on background utility dispatch queue; thread-safe.
// ============================================================================

import Foundation
import Darwin

// MARK: - Volume Verifier Service

/// Service running and classifying filesystem integrity verification passes.
final class VolumeVerifierService: @unchecked Sendable {
    /// Shared singleton instance.
    static let shared = VolumeVerifierService()

    init() {}

    /// Determines if a diskutil verification failure is due to permissions or lock contention rather than corruption.
    ///
    /// - Parameter result: Standard output/error string from diskutil.
    /// - Returns: True if failure is non-corruption related (e.g. error -69863 unprivileged).
    static func isNonCorruptionVerifyFailure(_ result: String) -> Bool {
        let lower = result.lowercased()
        return lower.contains("-69863") ||
               lower.contains("insufficient privileges") ||
               lower.contains("permission denied") ||
               lower.contains("not permitted") ||
               lower.contains("operation not permitted") ||
               lower.contains("-69888") ||
               lower.contains("couldn't unmount") ||
               lower.contains("could not unmount") ||
               lower.contains("couldn't be unmounted") ||
               lower.contains("could not be unmounted") ||
               lower.contains("unable to unmount") ||
               lower.contains("resource busy") ||
               lower.contains("volume is busy")
    }

    /// Classifies exit code and terminal output from diskutil verifyVolume into a structured health status.
    ///
    /// - Parameters:
    ///   - terminationStatus: Process exit status code from diskutil.
    ///   - output: Captured stdout/stderr text.
    ///   - didTimeout: True if the 180s watchdog killed the process.
    ///   - timeStr: Formatted timestamp string for display.
    /// - Returns: Tuple indicating (isHealthy, isSkipped, summaryText).
    static func classifyVolumeVerificationOutput(terminationStatus: Int32, output: String, didTimeout: Bool, timeStr: String) -> (isHealthy: Bool, isSkipped: Bool, summary: String) {
        if didTimeout {
            return (true, true, "Skipped (\(timeStr)): Verification timed out after 180s")
        }
        let passed = (terminationStatus == 0) &&
            (output.contains("appears to be OK") ||
             output.contains("Finished file system verification") ||
             output.contains("File system check exit code is 0"))
        if passed {
            return (true, false, "Verified OK (\(timeStr))")
        }
        if isNonCorruptionVerifyFailure(output) {
            let lower = output.lowercased()
            if output.contains("-69863") || lower.contains("insufficient privileges") || lower.contains("permission denied") || lower.contains("not permitted") {
                return (true, true, "Skipped (\(timeStr)): Requires administrator privileges (-69863)")
            }
            return (true, true, "Skipped (\(timeStr)): Volume busy / in use")
        }
        let lastLines = output.components(separatedBy: .newlines).filter { !$0.isEmpty }.suffix(2).joined(separator: " | ")
        let detail = lastLines.isEmpty ? "Exit code \(terminationStatus)" : lastLines
        return (false, false, "Failed (\(timeStr)): \(detail)")
    }

    /// Terminates a parent process and all child processes spawned by it (e.g. diskutil -> fsck_apfs).
    ///
    /// Invariant (SYS2-05): diskutil verifyVolume forks fsck_apfs, which inherits pipe handles.
    /// If only diskutil is killed with SIGKILL, the pipe remains open in fsck_apfs and
    /// pipe.fileHandleForReading.readToEnd() hangs indefinitely. We invoke /usr/bin/pkill -P
    /// to eliminate the entire process group before signaling the parent.
    ///
    /// - Parameters:
    ///   - pid: Parent process identifier.
    ///   - signal: POSIX signal to deliver (e.g. SIGTERM, SIGKILL).
    static func terminateProcessAndChildren(pid: pid_t, signal: Int32) {
        guard pid > 0 else { return }
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-\(signal)", "-P", "\(pid)"]
        try? pkill.run()
        pkill.waitUntilExit()
        kill(pid, signal)
    }

    /// Runs filesystem verification asynchronously on a background queue.
    ///
    /// - Parameters:
    ///   - target: Volume mount path or device BSD name (e.g. "/" or "disk0s2").
    ///   - timeoutSec: Watchdog timeout in seconds (default 180s).
    ///   - completion: Callback receiving (isHealthy, summaryText).
    func runVolumeVerification(
        target: String,
        timeoutSec: Double = 180.0,
        completion: @escaping (Bool, String) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            proc.arguments = ["verifyVolume", target]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            let readHandle = pipe.fileHandleForReading

            var ok = false
            var summary = ""
            do {
                try proc.run()

                // Watchdog timer in case diskutil or child fsck hangs on a wedged USB bridge
                let timeoutLock = NSLock()
                var timedOut = false
                var killWorkItem: DispatchWorkItem?
                let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
                watchdog.schedule(deadline: .now() + timeoutSec)
                watchdog.setEventHandler {
                    if proc.isRunning {
                        timeoutLock.lock()
                        timedOut = true
                        timeoutLock.unlock()
                        let pid = proc.processIdentifier
                        VolumeVerifierService.terminateProcessAndChildren(pid: pid, signal: SIGTERM)
                        proc.terminate()
                        // Escalate to SIGKILL after 2s if still alive
                        let escalation = DispatchWorkItem {
                            if pid > 0 {
                                VolumeVerifierService.terminateProcessAndChildren(pid: pid, signal: SIGKILL)
                            }
                            try? readHandle.close()
                        }
                        timeoutLock.lock()
                        killWorkItem = escalation
                        timeoutLock.unlock()
                        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0, execute: escalation)
                    }
                }
                watchdog.resume()

                let data = (try? readHandle.readToEnd()) ?? Data()
                proc.waitUntilExit()
                watchdog.cancel()
                timeoutLock.lock()
                killWorkItem?.cancel()
                let didTimeout = timedOut
                timeoutLock.unlock()
                try? readHandle.close()

                let output = String(decoding: data, as: UTF8.self)
                let timeStr = shortMonthDateFormatter.string(from: Date())
                let classified = VolumeVerifierService.classifyVolumeVerificationOutput(
                    terminationStatus: proc.terminationStatus,
                    output: output,
                    didTimeout: didTimeout,
                    timeStr: timeStr
                )
                ok = classified.isHealthy
                summary = classified.summary
            } catch {
                ok = true
                summary = "Skipped: Could not launch diskutil (\(error.localizedDescription))"
            }

            completion(ok, summary)
        }
    }
}
