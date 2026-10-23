// ============================================================================
// File: TelemetryProvider.swift
// Module: Layer 3 (Telemetry & Domain Engine)
// Purpose: Abstract storage telemetry protocol and implementations bridging
//          IOKit C11 hardware metrics, VFS statfs, and mock fault injection.
// Concurrency: Sendable value types and thread-safe providers.
// ============================================================================

import Foundation
import Darwin

// MARK: - Telemetry Models

/// Filesystem allocation metrics captured via Darwin `statfs` and APFS purgeable accounting.
struct FilesystemMountMetrics: Sendable, Equatable {
    var isMounted: Bool = false
    var mountPoint: String = ""
    var filesystemType: String = ""
    var isReadOnly: Bool = false
    var totalBytes: UInt64 = 0
    var freeBytes: UInt64 = 0
    var purgeableBytes: UInt64 = 0
    var usedBytes: UInt64 = 0
    var usedPercent: Double = 0.0
}

/// Descriptive volume information for UI pickers and CLI listings.
struct MountedVolumeInfo: Sendable, Equatable {
    let path: String
    let displayName: String
}

// MARK: - Telemetry Provider Protocol

/// Unified interface abstracting storage telemetry acquisition for testing and production.
protocol DiskTelemetryProvider: Sendable {
    /// Reads hardware descriptors and SMART metrics for a query or auto-detection.
    func readHardwareMetrics(query: String) -> DiskHardwareMetrics

    /// Enumerates all attached physical block storage devices.
    func listAllDevices(maxCount: Int) -> [DiskHardwareMetrics]

    /// Lists all local mounted volumes excluding special filesystems.
    func listLocalMountedVolumes() -> [MountedVolumeInfo]

    /// Resolves the mount path for a Darwin BSD name (e.g. "disk0" -> "/").
    func findMountPoint(forBsdName bsdName: String) -> String?

    /// Gathers filesystem capacity, free space, and purgeable bytes via `statfs`.
    func inspectFilesystem(mountPath: String) -> FilesystemMountMetrics

    /// Verifies existence and access of required subdirectories on a volume.
    func checkSubpaths(mountPoint: String, isMounted: Bool, requiredSubpaths: [String]) -> [String: Bool]

    /// Executes or retrieves a cached active 512B canary write/read probe.
    func runCanaryProbe(targetMount: String, force: Bool, nowTs: TimeInterval) -> CanaryProbeResult

    /// Retrieves host thermal pressure state from `ProcessInfo`.
    func currentHostThermalState() -> ProcessInfo.ThermalState
}

extension DiskTelemetryProvider {
    func listLocalMountedVolumes() -> [MountedVolumeInfo] {
        return IOKitTelemetryProvider.shared.listLocalMountedVolumes()
    }

    func runCanaryProbe(targetMount: String, force: Bool, nowTs: TimeInterval) -> CanaryProbeResult {
        return CanaryProbeService.shared.runCanaryCheck(targetMount: targetMount, force: force, nowTs: nowTs)
    }
}

struct IOKitTelemetryProvider: DiskTelemetryProvider {
    static let shared = IOKitTelemetryProvider()
    init() {}

    func readHardwareMetrics(query: String) -> DiskHardwareMetrics {
        var hw = DiskHardwareMetrics()
        DiskReadHardwareMetrics(query, &hw)
        return hw
    }

    func listAllDevices(maxCount: Int = 32) -> [DiskHardwareMetrics] {
        guard maxCount > 0 else { return [] }
        var raw = [DiskHardwareMetrics](repeating: DiskHardwareMetrics(), count: maxCount)
        let count = Int(DiskListAllDevices(&raw, Int32(maxCount)))
        return Array(raw.prefix(max(0, min(count, maxCount))))
    }

    func listLocalMountedVolumes() -> [MountedVolumeInfo] {
        var mounts: [MountedVolumeInfo] = []
        let numMounts = getfsstat(nil, 0, MNT_NOWAIT)
        guard numMounts > 0 else { return mounts }
        let allocCount = Int(numMounts) + 4
        var fsList = Array<Darwin.statfs>(repeating: Darwin.statfs(), count: allocCount)
        let mCount = getfsstat(&fsList, Int32(MemoryLayout<Darwin.statfs>.size * allocCount), MNT_NOWAIT)
        guard mCount > 0 else { return mounts }
        for i in 0..<min(Int(mCount), allocCount) {
            let volPath = cStringToSwift(fsList[i].f_mntonname)
            let flags = UInt32(fsList[i].f_flags)
            let isLocal = (flags & UInt32(MNT_LOCAL)) != 0
            if isLocal && (volPath.hasPrefix("/Volumes/") || volPath == "/") {
                let displayName = volPath == "/" ? "Macintosh HD (/)" : (volPath as NSString).lastPathComponent
                mounts.append(MountedVolumeInfo(path: volPath, displayName: displayName))
            }
        }
        return mounts
    }

    func runCanaryProbe(targetMount: String, force: Bool, nowTs: TimeInterval) -> CanaryProbeResult {
        return CanaryProbeService.shared.runCanaryCheck(targetMount: targetMount, force: force, nowTs: nowTs)
    }

    func findMountPoint(forBsdName bsdName: String) -> String? {
        guard !bsdName.isEmpty else { return nil }
        var cMount = [CChar](repeating: 0, count: 512)
        if DiskFindMountForBlockDevice(bsdName, &cMount, 512) {
            let path = String(cString: cMount)
            return path.isEmpty ? nil : path
        }
        return nil
    }

    func inspectFilesystem(mountPath: String) -> FilesystemMountMetrics {
        var metrics = FilesystemMountMetrics()
        guard !mountPath.isEmpty else { return metrics }
        var sfs = Darwin.statfs()
        guard statfs(mountPath, &sfs) == 0 else { return metrics }

        let resolvedMountPoint = (cStringToSwift(sfs.f_mntonname) as NSString).standardizingPath
        let resolvedInspect = (mountPath as NSString).standardizingPath
        let fsType = cStringToSwift(sfs.f_fstypename)

        let isValidMatch: Bool
        if resolvedInspect.hasPrefix("/Volumes/") {
            isValidMatch = (resolvedMountPoint == resolvedInspect) ||
                           (resolvedMountPoint.hasPrefix("/Volumes/") && resolvedInspect.hasPrefix(resolvedMountPoint + "/"))
        } else {
            isValidMatch = (resolvedMountPoint == resolvedInspect) ||
                           (resolvedMountPoint == "/" || resolvedMountPoint == "/System/Volumes/Data") ||
                           resolvedInspect.hasPrefix(resolvedMountPoint + "/")
        }

        guard isValidMatch else { return metrics }

        metrics.mountPoint = (resolvedMountPoint == "/System/Volumes/Data" && !resolvedInspect.hasPrefix("/System/Volumes/Data")) ? "/" : resolvedMountPoint
        metrics.filesystemType = fsType
        metrics.isMounted = true
        metrics.isReadOnly = (sfs.f_flags & UInt32(MNT_RDONLY)) != 0

        let bsize = UInt64(sfs.f_bsize)
        metrics.totalBytes = UInt64(sfs.f_blocks) * bsize
        let rawFreeBytes = UInt64(sfs.f_bavail) * bsize
        var effectiveFreeBytes = rawFreeBytes

        if fsType.lowercased() == "apfs" {
            let mountURL = URL(fileURLWithPath: metrics.mountPoint)
            if let vals = try? mountURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
               let importantFree = vals.volumeAvailableCapacityForImportantUsage,
               importantFree > 0 {
                let importantU64 = UInt64(importantFree)
                if importantU64 > rawFreeBytes && importantU64 <= metrics.totalBytes {
                    metrics.purgeableBytes = importantU64 - rawFreeBytes
                    effectiveFreeBytes = importantU64
                }
            }
        }

        metrics.freeBytes = effectiveFreeBytes
        metrics.usedBytes = metrics.totalBytes > metrics.freeBytes ? (metrics.totalBytes - metrics.freeBytes) : 0
        metrics.usedPercent = metrics.totalBytes > 0 ? (Double(metrics.usedBytes) / Double(metrics.totalBytes) * 100.0) : 0.0
        return metrics
    }

    func checkSubpaths(mountPoint: String, isMounted: Bool, requiredSubpaths: [String]) -> [String: Bool] {
        var subpathsStatus: [String: Bool] = [:]
        for subpath in requiredSubpaths {
            let cleanSub = subpath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            guard !cleanSub.isEmpty, !cleanSub.components(separatedBy: "/").contains("..") else {
                subpathsStatus[subpath] = false
                continue
            }
            let fullSubpath = (mountPoint as NSString).appendingPathComponent(cleanSub)
            var isDir: ObjCBool = false
            let exists = isMounted && FileManager.default.fileExists(atPath: fullSubpath, isDirectory: &isDir)
            subpathsStatus[subpath] = exists
        }
        return subpathsStatus
    }

    func currentHostThermalState() -> ProcessInfo.ThermalState {
        return ProcessInfo.processInfo.thermalState
    }
}

final class MockTelemetryProvider: DiskTelemetryProvider, @unchecked Sendable {
    private let lock = NSLock()
    var hardwareMetrics: DiskHardwareMetrics = DiskHardwareMetrics()
    var hardwareMetricsByQuery: [String: DiskHardwareMetrics] = [:]
    var allDevices: [DiskHardwareMetrics] = []
    var mountPointByBsd: [String: String] = [:]
    var filesystemMetrics: FilesystemMountMetrics = FilesystemMountMetrics()
    var filesystemMetricsByMount: [String: FilesystemMountMetrics] = [:]
    var subpathsOverride: [String: Bool]? = nil
    var hostThermalState: ProcessInfo.ThermalState = .nominal
    var mountedVolumes: [MountedVolumeInfo] = []
    var canaryResultOverride: CanaryProbeResult? = nil

    init() {}

    func withLock<T>(_ block: (MockTelemetryProvider) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return block(self)
    }

    func readHardwareMetrics(query: String) -> DiskHardwareMetrics {
        lock.lock()
        defer { lock.unlock() }
        if let specific = hardwareMetricsByQuery[query] {
            return specific
        }
        if let match = allDevices.first(where: {
            let bsd = cStringToSwift($0.bsdName)
            let ser = cStringToSwift($0.serialNumber)
            return (!bsd.isEmpty && bsd == query) || (!ser.isEmpty && ser == query)
        }) {
            return match
        }
        return hardwareMetrics
    }

    func listAllDevices(maxCount: Int) -> [DiskHardwareMetrics] {
        lock.lock()
        defer { lock.unlock() }
        return Array(allDevices.prefix(maxCount))
    }

    func listLocalMountedVolumes() -> [MountedVolumeInfo] {
        lock.lock()
        defer { lock.unlock() }
        return mountedVolumes
    }

    func findMountPoint(forBsdName bsdName: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return mountPointByBsd[bsdName]
    }

    func inspectFilesystem(mountPath: String) -> FilesystemMountMetrics {
        lock.lock()
        defer { lock.unlock() }
        if let specific = filesystemMetricsByMount[mountPath] {
            return specific
        }
        return filesystemMetrics
    }

    func runCanaryProbe(targetMount: String, force: Bool, nowTs: TimeInterval) -> CanaryProbeResult {
        lock.lock()
        let override = canaryResultOverride
        lock.unlock()
        if let override = override {
            return override
        }
        return CanaryProbeResult(ok: true, latencyMs: 1.0, error: "")
    }

    func checkSubpaths(mountPoint: String, isMounted: Bool, requiredSubpaths: [String]) -> [String: Bool] {
        lock.lock()
        defer { lock.unlock() }
        if let override = subpathsOverride { return override }
        var result: [String: Bool] = [:]
        for sub in requiredSubpaths {
            let clean = sub.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            if clean.isEmpty || clean.components(separatedBy: "/").contains("..") {
                result[sub] = false
            } else {
                result[sub] = isMounted
            }
        }
        return result
    }

    func currentHostThermalState() -> ProcessInfo.ThermalState {
        lock.lock()
        defer { lock.unlock() }
        return hostThermalState
    }
}
