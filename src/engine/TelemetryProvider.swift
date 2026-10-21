import Foundation
import Darwin

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

protocol DiskTelemetryProvider: Sendable {
    func readHardwareMetrics(query: String) -> DiskHardwareMetrics
    func listAllDevices(maxCount: Int) -> [DiskHardwareMetrics]
    func findMountPoint(forBsdName bsdName: String) -> String?
    func inspectFilesystem(mountPath: String) -> FilesystemMountMetrics
    func checkSubpaths(mountPoint: String, isMounted: Bool, requiredSubpaths: [String]) -> [String: Bool]
    func currentHostThermalState() -> ProcessInfo.ThermalState
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
    var allDevices: [DiskHardwareMetrics] = []
    var mountPointByBsd: [String: String] = [:]
    var filesystemMetrics: FilesystemMountMetrics = FilesystemMountMetrics()
    var subpathsOverride: [String: Bool]? = nil
    var hostThermalState: ProcessInfo.ThermalState = .nominal

    init() {}

    func withLock<T>(_ block: (MockTelemetryProvider) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return block(self)
    }

    func readHardwareMetrics(query: String) -> DiskHardwareMetrics {
        lock.lock()
        defer { lock.unlock() }
        return hardwareMetrics
    }

    func listAllDevices(maxCount: Int) -> [DiskHardwareMetrics] {
        lock.lock()
        defer { lock.unlock() }
        return Array(allDevices.prefix(maxCount))
    }

    func findMountPoint(forBsdName bsdName: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return mountPointByBsd[bsdName]
    }

    func inspectFilesystem(mountPath: String) -> FilesystemMountMetrics {
        lock.lock()
        defer { lock.unlock() }
        return filesystemMetrics
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
