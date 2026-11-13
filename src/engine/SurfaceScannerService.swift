// ============================================================================
// File: SurfaceScannerService.swift
// Module: Layer 3 (Telemetry & Domain Engine)
// Purpose: Non-destructive direct I/O media surface scanning and benchmark engine
//          using fcntl(F_NOCACHE) with cancellation tokens and live ETA tracking.
// Concurrency: Executes on background utility queue; cancellation token thread-safe.
// ============================================================================

import Foundation
import Darwin

// Darwin VFS and APFS Dataless Stub Policy Constants
private let kIOPolTypeVfsMaterializeDataless: Int32 = 3 // IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
private let kIOPolScopeThread: Int32 = 1                // IOPOL_SCOPE_THREAD
private let kIOPolMaterializeOff: Int32 = 1             // IOPOL_MATERIALIZE_DATALESS_FILES_OFF
private let kSFDatalessFlag: UInt32 = 0x4000_0000       // SF_DATALESS (st_flags on dataless APFS stubs)

// MARK: - Surface Scanner Service

/// Service providing non-destructive direct media read benchmarking and bad-sector detection.
final class SurfaceScannerService: @unchecked Sendable {
    /// Shared singleton instance.
    static let shared = SurfaceScannerService()

    private let lock = NSLock()
    private(set) var lastDamagedExtents: [DamagedPhysicalExtent] = []
    private var damagedExtentsByMount: [String: [DamagedPhysicalExtent]] = [:]

    init() {}

    /// Returns recorded physical damaged extents for a specific mount point.
    func damagedExtents(forMount mountPath: String) -> [DamagedPhysicalExtent] {
        guard !mountPath.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        let norm = (mountPath as NSString).standardizingPath
        if let direct = damagedExtentsByMount[norm] {
            return direct
        }
        return damagedExtentsByMount[mountPath] ?? []
    }

    /// Operational tiers for non-destructive surface scanning.
    enum SurfaceScanMode: String, CaseIterable, Identifiable, Hashable, Sendable {
        case quick = "quick"
        case standard = "standard"
        case full = "full"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .quick: return "Quick Probe (64 MB)"
            case .standard: return "Standard Scan (2 GB)"
            case .full: return "Full Volume Scan"
            }
        }

        var shortLabel: String {
            switch self {
            case .quick: return "Quick (64 MB)"
            case .standard: return "Standard (2 GB)"
            case .full: return "Full Volume"
            }
        }

        var modeDescription: String {
            switch self {
            case .quick:
                return "Samples up to 120 files (256 KB/file, 64 MB cap) using F_NOCACHE direct reads (~0.2s)."
            case .standard:
                return "Scans up to 2,000 files (2 MB/file, 2 GB cap) across the volume using uncached reads (~3–5s)."
            case .full:
                return "Streams all readable allocated files across the volume in 1 MB uncached blocks with live throughput & ETA."
            }
        }

        var maxBytes: UInt64 {
            switch self {
            case .quick: return 64 * 1024 * 1024
            case .standard: return 2 * 1024 * 1024 * 1024
            case .full: return UInt64.max
            }
        }

        var maxFiles: Int {
            switch self {
            case .quick: return 120
            case .standard: return 2_000
            case .full: return Int.max
            }
        }

        var maxBytesPerFile: Int {
            switch self {
            case .quick: return 256 * 1024
            case .standard: return 2 * 1024 * 1024
            case .full: return Int.max
            }
        }

        var chunkSize: Int {
            switch self {
            case .quick: return 256 * 1024
            case .standard, .full: return 1024 * 1024
            }
        }
    }

    struct SurfaceScanProgress: Sendable {
        let mode: SurfaceScanMode
        let filesScanned: Int
        let bytesScanned: UInt64
        let targetBytes: UInt64
        let readErrors: Int
        let throughputMBps: Double
        let fractionCompleted: Double
        let estimatedRemainingSec: Double?
        let currentFile: String

        var formattedBytesScanned: String {
            ByteCountFormatter.string(fromByteCount: Int64(bytesScanned), countStyle: .file)
        }

        var formattedTargetBytes: String {
            ByteCountFormatter.string(fromByteCount: Int64(targetBytes), countStyle: .file)
        }

        var formattedThroughput: String {
            String(format: "%.1f MB/s", throughputMBps)
        }

        var formattedPercent: String {
            String(format: "%.1f%%", min(100.0, max(0.0, fractionCompleted * 100.0)))
        }

        var formattedETA: String? {
            guard let sec = estimatedRemainingSec, sec > 0 else { return nil }
            if sec < 60 {
                return String(format: "%.0fs", sec)
            } else if sec < 3600 {
                let m = Int(sec) / 60
                let s = Int(sec) % 60
                return "\(m)m \(s)s"
            } else {
                let h = Int(sec) / 3600
                let m = (Int(sec) % 3600) / 60
                return "\(h)h \(m)m"
            }
        }
    }

    final class SurfaceScanCancellationToken: @unchecked Sendable {
        private let lock = NSLock()
        private var _isCancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _isCancelled
        }

        func cancel() {
            lock.lock()
            _isCancelled = true
            lock.unlock()
        }
    }

    /// Collects regular, same-filesystem candidate files without triggering dataless downloads or firmlink loops.
    private static func collectSafeScanCandidates(
        rootPath: String,
        mode: SurfaceScanMode,
        maxBytesBudget: UInt64,
        maxFilesBudget: Int,
        isCancelled: () -> Bool
    ) -> [(path: String, size: UInt64)] {
        // Disable APFS dataless materialization so iCloud/AssetsV2 files are never downloaded
        _ = setiopolicy_np(kIOPolTypeVfsMaterializeDataless, kIOPolScopeThread, kIOPolMaterializeOff)

        var rootStat = stat()
        guard lstat(rootPath, &rootStat) == 0 else { return [] }
        let rootDev = rootStat.st_dev

        var candidates: [(path: String, size: UInt64)] = []
        var accumulatedBytes: UInt64 = 0

        guard let cPath = rootPath.cString(using: .utf8) else { return [] }
        var paths: [UnsafeMutablePointer<CChar>?] = [strdup(cPath), nil]
        defer { if let p = paths[0] { free(p) } }

        // FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV guarantees we stay on rootDev and never cross /dev or firmlinks
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return [] }
        defer { fts_close(fts) }

        while let ent = fts_read(fts) {
            if isCancelled() { break }
            let info = Int32(ent.pointee.fts_info)

            if info == FTS_D {
                let pathStr = String(cString: ent.pointee.fts_path)
                if pathStr == "/dev" || pathStr == "/net" || pathStr == "/home" || pathStr == "/System/Volumes" {
                    fts_set(fts, ent, FTS_SKIP)
                    continue
                }
            }

            guard info == FTS_F, let stPtr = ent.pointee.fts_statp else { continue }
            let st = stPtr.pointee
            guard st.st_dev == rootDev else { continue }
            guard (st.st_mode & S_IFMT) == S_IFREG else { continue }
            guard (st.st_flags & kSFDatalessFlag) == 0 else { continue }
            guard st.st_size > 0 else { continue }

            let fileSize = UInt64(st.st_size)
            candidates.append((String(cString: ent.pointee.fts_path), fileSize))
            accumulatedBytes &+= fileSize

            if candidates.count >= maxFilesBudget || accumulatedBytes >= maxBytesBudget {
                break
            }
        }
        return candidates
    }

    func runSurfaceReadScan(
        mountPoint: String,
        totalBytes: UInt64,
        freeBytes: UInt64,
        mode: SurfaceScanMode = .quick,
        maxBytesToScan: UInt64? = nil,
        cancellationToken: SurfaceScanCancellationToken? = nil,
        progressHandler: ((SurfaceScanProgress) -> Void)? = nil
    ) -> (ok: Bool, filesScanned: Int, bytesScanned: UInt64, readErrors: Int, elapsedMs: Double, summary: String) {
        guard !mountPoint.isEmpty else {
            return (false, 0, 0, 1, 0.0, "Surface scan aborted: Target volume is not mounted.")
        }

        let scanRoot: String
        if mountPoint == "/" {
            scanRoot = (mode == .quick) ? "/System/Library/CoreServices" : "/"
        } else {
            scanRoot = mountPoint
        }

        if ParallelDriveProber.shared.isMountQuarantined(mountPoint) || (scanRoot != mountPoint && ParallelDriveProber.shared.isMountQuarantined(scanRoot)) {
            return (false, 0, 0, 1, 0.0, "Surface scan aborted: Storage controller on '\(mountPoint)' is unresponsive (quarantined).")
        }

        return PowerManagementService.shared.withPreventIdleSleepAssertion(reason: "DiskHealthMonitor Surface Scan (\(mode.displayName))") {
            let effectiveMaxBytes = maxBytesToScan ?? mode.maxBytes
            let effectiveMaxFiles = mode.maxFiles
            let maxPerFile = mode.maxBytesPerFile
            let bufSize = mode.chunkSize

            let allocatedVolumeBytes: UInt64 = {
                if totalBytes > freeBytes {
                    return max(1, totalBytes - freeBytes)
                }
                return max(1, totalBytes)
            }()

            let estimatedTargetBytes: UInt64 = {
                switch mode {
                case .quick, .standard:
                    return min(effectiveMaxBytes, allocatedVolumeBytes)
                case .full:
                    return allocatedVolumeBytes
                }
            }()

            let isCancelledClosure = { cancellationToken?.isCancelled == true }

            let start = DispatchTime.now()
            var lastProgressReportNs = start.uptimeNanoseconds

            // Collect safe file candidates using kernel dataless protection and FTS_XDEV
            let candidates = Self.collectSafeScanCandidates(
                rootPath: scanRoot,
                mode: mode,
                maxBytesBudget: effectiveMaxBytes,
                maxFilesBudget: effectiveMaxFiles,
                isCancelled: isCancelledClosure
            )

            if isCancelledClosure() {
                let summary = String(
                    format: "CANCELLED [%@] after 0 files (0 B read, 0 I/O errors)",
                    mode.shortLabel
                )
                ConfigManager.shared.log("Surface read scan on '\(scanRoot)': \(summary)")
                return (true, 0, 0, 0, 0.0, summary)
            }

            if candidates.isEmpty {
                let summary = "WARNING: Surface scan (\(mode.shortLabel)) completed with 0 readable files sampled on '\(scanRoot)' (insufficient regular files or read permissions)."
                ConfigManager.shared.log("Surface read scan on '\(scanRoot)': \(summary)")
                return (false, 0, 0, 0, 0.0, summary)
            }

            var filesScanned = 0
            var bytesScanned: UInt64 = 0
            var readErrors = 0
            var wasCancelled = false
            var currentDamagedExtents: [DamagedPhysicalExtent] = []

            let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 4096)
            defer { buffer.deallocate() }

            let emitProgress: (String, Bool) -> Void = { currentPath, force in
                guard let handler = progressHandler else { return }
                let nowNs = DispatchTime.now().uptimeNanoseconds
                if !force && (nowNs - lastProgressReportNs) < 100_000_000 { return }
                lastProgressReportNs = nowNs

                let elapsedSec = max(0.001, Double(nowNs - start.uptimeNanoseconds) / 1_000_000_000.0)
                let mbps = (Double(bytesScanned) / (1024.0 * 1024.0)) / elapsedSec

                let fraction: Double
                if mode == .full {
                    fraction = min(0.99, Double(bytesScanned) / Double(max(1, estimatedTargetBytes)))
                } else {
                    let byteFrac = Double(bytesScanned) / Double(max(1, effectiveMaxBytes))
                    let fileFrac = Double(filesScanned) / Double(max(1, effectiveMaxFiles))
                    fraction = min(0.99, max(byteFrac, fileFrac))
                }

                let eta: Double?
                if fraction > 0.01 && mbps > 0.1 {
                    let remainingBytes = estimatedTargetBytes > bytesScanned ? (estimatedTargetBytes - bytesScanned) : 0
                    eta = Double(remainingBytes) / (mbps * 1024.0 * 1024.0)
                } else {
                    eta = nil
                }

                handler(SurfaceScanProgress(
                    mode: mode,
                    filesScanned: filesScanned,
                    bytesScanned: bytesScanned,
                    targetBytes: estimatedTargetBytes,
                    readErrors: readErrors,
                    throughputMBps: mbps,
                    fractionCompleted: fraction,
                    estimatedRemainingSec: eta,
                    currentFile: (currentPath as NSString).lastPathComponent
                ))
            }

            outerLoop: for candidate in candidates {
                if isCancelledClosure() {
                    wasCancelled = true
                    break
                }
                if bytesScanned >= effectiveMaxBytes || filesScanned >= effectiveMaxFiles {
                    break
                }

                let path = candidate.path
                let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                if fd < 0 { continue }
                _ = fcntl(fd, F_NOCACHE, 1)

                var st = stat()
                guard fstat(fd, &st) == 0,
                      (st.st_mode & S_IFMT) == S_IFREG,
                      (st.st_flags & kSFDatalessFlag) == 0,
                      st.st_size > 0 else {
                    close(fd)
                    continue
                }

                let fileSize = off_t(st.st_size)
                let chunkOff = off_t(bufSize)
                let step: off_t = {
                    switch mode {
                    case .quick:    return max(chunkOff, fileSize / 4)
                    case .standard: return max(chunkOff, fileSize / 32)
                    case .full:     return chunkOff
                    }
                }()

                let fileTargetBytes = min(UInt64(fileSize), UInt64(maxPerFile))
                var fileBytesRead: UInt64 = 0
                var countedFile = false
                var offset: off_t = 0

                while offset < fileSize && fileBytesRead < fileTargetBytes && bytesScanned < effectiveMaxBytes {
                    if isCancelledClosure() {
                        wasCancelled = true
                        close(fd)
                        break outerLoop
                    }

                    let remainingForFile = fileTargetBytes - fileBytesRead
                    let remainingGlobal = effectiveMaxBytes - bytesScanned
                    let toRead = Int(min(off_t(bufSize), min(off_t(remainingForFile), off_t(remainingGlobal))))
                    if toRead <= 0 { break }

                    let n = pread(fd, buffer, toRead, offset)
                    if n > 0 {
                        let readU64 = UInt64(n)
                        fileBytesRead &+= readU64
                        bytesScanned &+= readU64
                        if !countedFile {
                            filesScanned += 1
                            countedFile = true
                        }
                        emitProgress(path, false)
                        offset += (mode == .full) ? off_t(n) : step
                    } else if n == 0 {
                        // EOF on compressed or truncated file; break without spinning
                        break
                    } else {
                        let err = errno
                        if err == EINTR { continue }
                        if err == EIO || err == ENXIO || err == ETIMEDOUT {
                            readErrors += 1
                            var physOff: UInt64 = 0
                            var contig: UInt64 = 0
                            let l2pRc = DiskResolvePhysicalExtent(fd, offset, off_t(toRead), &physOff, &contig)
                            if currentDamagedExtents.count < 256 {
                                let damaged = DamagedPhysicalExtent(
                                    filePath: path,
                                    logicalOffset: UInt64(offset),
                                    physicalLbaOffset: (l2pRc == 0) ? physOff : 0,
                                    contiguousBytes: (l2pRc == 0 && contig > 0) ? contig : UInt64(toRead),
                                    errorCode: err
                                )
                                currentDamagedExtents.append(damaged)
                            }
                            if l2pRc == 0 {
                                ConfigManager.shared.log("DAMAGED EXTENT (SCAN-02): '\(path)' @ logical offset \(offset) -> physical offset \(physOff) (\(contig) bytes, errno: \(err))")
                            } else {
                                ConfigManager.shared.log("DAMAGED EXTENT (SCAN-02): '\(path)' @ logical offset \(offset) (F_LOG2PHYS unavailable, errno: \(err))")
                            }
                        }
                        offset += step
                    }
                }
                close(fd)
            }

            emitProgress("", true)

            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
            let elapsedSec = max(0.001, elapsedMs / 1000.0)
            let avgMBps = (Double(bytesScanned) / (1024.0 * 1024.0)) / elapsedSec

            if wasCancelled {
                let summary = String(
                    format: "CANCELLED [%@] after %d files (%@ read at %.1f MB/s in %.2f s, %d I/O errors)",
                    mode.shortLabel, filesScanned, formatBytes(bytesScanned), avgMBps, elapsedSec, readErrors
                )
                ConfigManager.shared.log("Surface read scan on '\(scanRoot)': \(summary)")
                return (readErrors == 0, filesScanned, bytesScanned, readErrors, elapsedMs, summary)
            }

            if filesScanned == 0 {
                let summary = "WARNING: Surface scan (\(mode.shortLabel)) completed with 0 readable files sampled on '\(scanRoot)' (insufficient regular files or read permissions)."
                ConfigManager.shared.log("Surface read scan on '\(scanRoot)': \(summary)")
                return (false, 0, 0, readErrors, elapsedMs, summary)
            }

            lock.lock()
            self.lastDamagedExtents = currentDamagedExtents
            let normMount = (mountPoint as NSString).standardizingPath
            self.damagedExtentsByMount[normMount] = currentDamagedExtents
            self.damagedExtentsByMount[mountPoint] = currentDamagedExtents
            lock.unlock()

            let ok = (readErrors == 0)
            let timeStr = elapsedMs >= 1000.0 ? String(format: "%.2f s", elapsedSec) : String(format: "%.1f ms", elapsedMs)
            let summary = ok
                ? String(format: "PASSED [%@] (%d files, %@ read directly from media at %.1f MB/s in %@, 0 I/O errors)", mode.shortLabel, filesScanned, formatBytes(bytesScanned), avgMBps, timeStr)
                : String(format: "FAILED [%@] (%d physical read errors across %d files, %@ read)", mode.shortLabel, readErrors, filesScanned, formatBytes(bytesScanned))
            ConfigManager.shared.log("Surface read scan on '\(scanRoot)': \(summary)")
            return (ok, filesScanned, bytesScanned, readErrors, elapsedMs, summary)
        }
    }
}

typealias SurfaceScanMode = SurfaceScannerService.SurfaceScanMode
typealias SurfaceScanProgress = SurfaceScannerService.SurfaceScanProgress
typealias SurfaceScanCancellationToken = SurfaceScannerService.SurfaceScanCancellationToken
