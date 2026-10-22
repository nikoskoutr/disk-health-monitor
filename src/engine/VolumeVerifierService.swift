import Foundation
import Darwin

final class VolumeVerifierService: @unchecked Sendable {
    static let shared = VolumeVerifierService()

    init() {}

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

    static func terminateProcessAndChildren(pid: pid_t, signal: Int32) {
        guard pid > 0 else { return }
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-\(signal)", "-P", "\(pid)"]
        try? pkill.run()
        pkill.waitUntilExit()
        kill(pid, signal)
    }

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
