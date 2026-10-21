import Foundation
import Darwin

struct CanaryProbeResult: Sendable, Equatable {
    let ok: Bool
    let latencyMs: Double
    let error: String
}

final class CanaryProbeService: @unchecked Sendable {
    static let shared = CanaryProbeService()

    private let lock = NSLock()
    private var lastRunTime: TimeInterval = 0
    private var cachedResult = CanaryProbeResult(ok: true, latencyMs: 0.0, error: "")

    init() {}

    func resetCache() {
        lock.lock()
        lastRunTime = 0
        cachedResult = CanaryProbeResult(ok: true, latencyMs: 0.0, error: "")
        lock.unlock()
    }

    func runCanaryCheck(targetMount: String, force: Bool, nowTs: TimeInterval = Date().timeIntervalSince1970) -> CanaryProbeResult {
        lock.lock()
        if !force && (nowTs - lastRunTime) < 300 && lastRunTime > 0 {
            let res = cachedResult
            lock.unlock()
            return res
        }
        lock.unlock()

        var result = performSingleCanaryPass(targetMount: targetMount)
        if !result.ok || result.latencyMs > 300.0 {
            usleep(50_000) // 50ms settle before retry pass
            let secondPass = performSingleCanaryPass(targetMount: targetMount)
            if secondPass.ok || !result.ok {
                result = secondPass
            }
        }

        lock.lock()
        cachedResult = result
        lastRunTime = nowTs
        lock.unlock()

        return result
    }

    func runCanaryCheckResult(targetMount: String, force: Bool, nowTs: TimeInterval = Date().timeIntervalSince1970) -> Result<CanaryProbeResult, DiskHealthError> {
        let res = runCanaryCheck(targetMount: targetMount, force: force, nowTs: nowTs)
        if res.ok {
            return .success(res)
        } else {
            return .failure(.canaryFailed(reason: res.error))
        }
    }

    private func performSingleCanaryPass(targetMount: String) -> CanaryProbeResult {
        // On sealed macOS root volume ("/"), probe via /System/Volumes/Data/private/tmp if writable,
        // avoiding guaranteed EROFS on "/.disk_health_canary"
        let effectiveDir: String
        if targetMount == "/" && FileManager.default.isWritableFile(atPath: "/System/Volumes/Data/private/tmp") {
            effectiveDir = "/System/Volumes/Data/private/tmp"
        } else {
            effectiveDir = targetMount
        }

        let canaryPath = (effectiveDir as NSString).appendingPathComponent(".disk_health_canary_\(getuid())")
        let token = "DISK_HEALTH_CANARY_\(UUID().uuidString)\n"
        guard let data = token.data(using: .utf8) else {
            return CanaryProbeResult(ok: false, latencyMs: 0, error: "Encoding error")
        }

        let start = DispatchTime.now()
        // Use O_NOFOLLOW to prevent symlink truncation attacks and O_CLOEXEC to prevent fd inheritance
        let fd = open(canaryPath, O_CREAT | O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd < 0 {
            let errCode = errno
            if errCode == EPERM || errCode == EACCES || errCode == EROFS {
                // Fallback to active read/directory probe on the mount directory itself
                let readStart = DispatchTime.now()
                guard let dir = opendir(targetMount) else {
                    let dirErr = String(cString: strerror(errno))
                    return CanaryProbeResult(ok: false, latencyMs: 0, error: "opendir failed: \(dirErr)")
                }
                var entryCount = 0
                while let entry = readdir(dir) {
                    entryCount += 1
                    _ = entry.pointee.d_ino
                }
                closedir(dir)
                if entryCount == 0 {
                    return CanaryProbeResult(ok: false, latencyMs: 0, error: "readdir returned 0 entries")
                }
                let elapsedNs = DispatchTime.now().uptimeNanoseconds - readStart.uptimeNanoseconds
                let elapsedMs = Double(elapsedNs) / 1_000_000.0
                return CanaryProbeResult(ok: true, latencyMs: elapsedMs, error: "")
            }
            let errStr = String(cString: strerror(errCode))
            return CanaryProbeResult(ok: false, latencyMs: 0, error: "open write failed: \(errStr)")
        }

        let written = data.withUnsafeBytes { ptr -> Int in
            guard let base = ptr.baseAddress else { return -1 }
            return write(fd, base, data.count)
        }
        if written != data.count {
            let errStr = String(cString: strerror(errno))
            close(fd)
            unlink(canaryPath)
            return CanaryProbeResult(ok: false, latencyMs: 0, error: "write failed: \(errStr)")
        }

        if fsync(fd) != 0 {
            let errStr = String(cString: strerror(errno))
            close(fd)
            unlink(canaryPath)
            return CanaryProbeResult(ok: false, latencyMs: 0, error: "fsync failed: \(errStr)")
        }
        close(fd)

        guard let readBack = try? String(contentsOfFile: canaryPath, encoding: .utf8), readBack == token else {
            unlink(canaryPath)
            return CanaryProbeResult(ok: false, latencyMs: 0, error: "readback verification mismatch")
        }

        unlink(canaryPath)
        let elapsedNs = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        let elapsedMs = Double(elapsedNs) / 1_000_000.0
        return CanaryProbeResult(ok: true, latencyMs: elapsedMs, error: "")
    }
}
