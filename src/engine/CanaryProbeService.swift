// ============================================================================
// File: CanaryProbeService.swift
// Module: Layer 3 (Telemetry & Domain Engine)
// Purpose: Non-destructive active I/O verification executing sector-aligned (512B)
//          in-place pwrite, fsync, and pread probes with F_NOCACHE.
// Concurrency: Thread-safe via NSLock; memoizes results in a 300s cache per mount.
// ============================================================================

import Foundation
import Darwin

// MARK: - Canary Models

/// Outcome of an active write/read canary probe on a storage volume.
struct CanaryProbeResult: Sendable, Equatable {
    /// True if the write-fsync-readback cycle completed successfully.
    let ok: Bool

    /// End-to-end I/O latency in milliseconds.
    let latencyMs: Double

    /// Descriptive error string if probe failed, or empty string on success.
    let error: String
}

// MARK: - Canary Probe Service

/// Service managing non-destructive active media health verification.
final class CanaryProbeService: @unchecked Sendable {
    /// Shared singleton instance.
    static let shared = CanaryProbeService()

    private let lock = NSLock()
    private var cacheByMount: [String: (timestamp: TimeInterval, result: CanaryProbeResult)] = [:]

    init() {}

    /// Clears the 300-second per-mount canary result cache.
    func resetCache() {
        lock.lock()
        cacheByMount.removeAll()
        lock.unlock()
    }

    /// Executes an active canary probe on target volume, using 300s cache unless forced.
    ///
    /// - Parameters:
    ///   - targetMount: Filesystem mount path (e.g. "/" or "/Volumes/T7").
    ///   - force: If true, bypasses the 300s cache and executes live I/O immediately.
    ///   - nowTs: Current Unix epoch timestamp for cache expiration.
    /// - Returns: `CanaryProbeResult` indicating probe health and I/O latency.
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
            usleep(50_000) // 50ms settle before retry pass to filter transient scheduler spikes
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

    /// Synchronous variant returning a Result type for CLI or export callers.
    func runCanaryCheckResult(targetMount: String, force: Bool, nowTs: TimeInterval = Date().timeIntervalSince1970) -> Result<CanaryProbeResult, DiskHealthError> {
        let res = runCanaryCheck(targetMount: targetMount, force: force, nowTs: nowTs)
        if res.ok {
            return .success(res)
        } else {
            return .failure(.canaryFailed(reason: res.error))
        }
    }

    // MARK: - Internal I/O Execution

    /// Executes a single in-place 512B write/fsync/readback pass.
    ///
    /// Invariants:
    /// 1. Sealed Root Redirection: If targetMount == "/", probes via `/System/Volumes/Data/private/tmp`
    ///    to avoid guaranteed EROFS on macOS sealed system snapshot volumes.
    /// 2. Sector Alignment (UAT2-01): Buffer is padded to 512 bytes so `fcntl(F_NOCACHE)`
    ///    never fails with EINVAL on FAT32/exFAT kernel drivers.
    /// 3. In-Place I/O: Uses `O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC` to mutate the same
    ///    hidden `.disk_health_canary_<uid>` file, eliminating APFS B-tree directory node churn.
    /// 4. Orphan Self-Healing (UAT2-04): If an orphaned canary file with 0400 permissions was left
    ///    behind from an interrupted pass, attempts `unlink()` and retries `open()`.
    /// 5. Read-Only Fallback: On write-restricted or read-only mounts (EROFS/EACCES), falls back
    ///    to active `opendir()` + `readdir()` directory traversal.
    private func performSingleCanaryPass(targetMount: String) -> CanaryProbeResult {
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
