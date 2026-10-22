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
    private var cacheByMount: [String: (timestamp: TimeInterval, result: CanaryProbeResult)] = [:]

    init() {}

    func resetCache() {
        lock.lock()
        cacheByMount.removeAll()
        lock.unlock()
    }

    func runCanaryCheck(targetMount: String, force: Bool, nowTs: TimeInterval = Date().timeIntervalSince1970) -> CanaryProbeResult {
        let key = targetMount.isEmpty ? "/" : targetMount
        lock.lock()
        if !force, let entry = cacheByMount[key], (nowTs - entry.timestamp) < 300, entry.timestamp > 0 {
            let res = entry.result
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
        cacheByMount[key] = (timestamp: nowTs, result: result)
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
        let header = "DISK_HEALTH_CANARY_\(UUID().uuidString)\n"
        guard var data = header.data(using: .utf8) else {
            return CanaryProbeResult(ok: false, latencyMs: 0, error: "Encoding error")
        }
        // Pad to 512-byte sector boundary so F_NOCACHE pwrite/pread never fails with EINVAL on exFAT/FAT32
        if data.count < 512 {
            data.append(Data(repeating: 0x20, count: 512 - data.count - 1))
            data.append(0x0A)
        }

        let start = DispatchTime.now()
        // Use O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC for in-place verification without directory B-tree churn
        var fd = open(canaryPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        var openErrno = (fd < 0) ? errno : 0
        if fd < 0 && (openErrno == EACCES || openErrno == EPERM) {
            // Self-heal if an orphaned canary file with 0400 permissions was left behind on a writable mount
            if unlink(canaryPath) == 0 {
                fd = open(canaryPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
                openErrno = (fd < 0) ? errno : 0
            }
        }
        if fd < 0 {
            if openErrno == EPERM || openErrno == EACCES || openErrno == EROFS {
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
            let errStr = String(cString: strerror(openErrno))
            return CanaryProbeResult(ok: false, latencyMs: 0, error: "open write failed: \(errStr)")
        }

        _ = fcntl(fd, F_NOCACHE, 1)

        var written = data.withUnsafeBytes { ptr -> Int in
            guard let base = ptr.baseAddress else { return -1 }
            return pwrite(fd, base, data.count, 0)
        }
        if written < 0 && errno == EINVAL {
            // Filesystem driver rejected F_NOCACHE unaligned buffer; disable F_NOCACHE and retry pwrite
            _ = fcntl(fd, F_NOCACHE, 0)
            written = data.withUnsafeBytes { ptr -> Int in
                guard let base = ptr.baseAddress else { return -1 }
                return pwrite(fd, base, data.count, 0)
            }
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

        var readBuf = [UInt8](repeating: 0, count: data.count)
        let bytesRead = readBuf.withUnsafeMutableBytes { ptr -> Int in
            guard let base = ptr.baseAddress else { return -1 }
            return pread(fd, base, data.count, 0)
        }
        close(fd)

        guard bytesRead == data.count, readBuf.elementsEqual(data) else {
            unlink(canaryPath)
            return CanaryProbeResult(ok: false, latencyMs: 0, error: "readback verification mismatch")
        }

        let elapsedNs = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        let elapsedMs = Double(elapsedNs) / 1_000_000.0
        return CanaryProbeResult(ok: true, latencyMs: elapsedMs, error: "")
    }
}
