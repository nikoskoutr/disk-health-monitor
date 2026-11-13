// ============================================================================
// File: ParallelDriveProber.swift
// Module: Layer 3 (Telemetry & Domain Engine)
// Purpose: Bounded parallel per-drive telemetry prober with a 3-second circuit
//          breaker. Prevents dead/hung USB-SATA/NVMe bridges from freezing VFS
//          statfs or canary polling for healthy drives across the fleet.
// Concurrency: Thread-safe NSLock + DispatchGroup with bounded maxConcurrency.
// ============================================================================

import Foundation

/// Input descriptor for a single physical storage device probe.
struct DriveProbeTarget: Sendable {
    let driveKey: String
    let mountPath: String
    let isInternal: Bool
    let runCanary: Bool
    var requiredSubpaths: [String] = []
    var inspectApfs: Bool = false
}

/// Output captured by `ParallelDriveProber` for one storage device.
struct DriveProbeResult: Sendable {
    let driveKey: String
    let fsMetrics: FilesystemMountMetrics
    let subpathsStatus: [String: Bool]
    let apfsContainer: ApfsContainerFleetMetrics?
    let canaryResult: CanaryProbeResult?
    let timedOut: Bool
    let isQuarantined: Bool

    init(
        driveKey: String,
        fsMetrics: FilesystemMountMetrics,
        subpathsStatus: [String: Bool] = [:],
        apfsContainer: ApfsContainerFleetMetrics? = nil,
        canaryResult: CanaryProbeResult?,
        timedOut: Bool,
        isQuarantined: Bool
    ) {
        self.driveKey = driveKey
        self.fsMetrics = fsMetrics
        self.subpathsStatus = subpathsStatus
        self.apfsContainer = apfsContainer
        self.canaryResult = canaryResult
        self.timedOut = timedOut
        self.isQuarantined = isQuarantined
    }
}

/// Decoupled bounded parallel drive prober replacing monolithic serialized polling.
/// If a storage controller hangs inside Darwin `statfs()` or `open()`, the 3s circuit breaker
/// drops waiting on that worker and quarantines the mount for 120s so other drives update immediately.
final class ParallelDriveProber: @unchecked Sendable {
    static let shared = ParallelDriveProber()

    private static let quarantineTtlSeconds: TimeInterval = 120.0

    private let lock = NSLock()
    private var quarantinedUntilByMount: [String: TimeInterval] = [:]
    private var inFlightMounts = Set<String>()
    private let probeQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "io.github.disk-health-monitor.parallel-prober"
        q.maxConcurrentOperationCount = 4
        q.qualityOfService = .utility
        return q
    }()

    private init() {}

    private func isProtectedFromQuarantine(mountPath: String, isInternal: Bool) -> Bool {
        return isInternal || mountPath == "/" || mountPath == "/System/Volumes/Data"
    }

    /// Queries whether a mount path is currently quarantined by an active circuit breaker.
    func isMountQuarantined(_ mountPath: String) -> Bool {
        guard !mountPath.isEmpty, mountPath != "/", mountPath != "/System/Volumes/Data" else { return false }
        let nowTs = Date().timeIntervalSince1970
        lock.lock()
        defer { lock.unlock() }
        if let until = quarantinedUntilByMount[mountPath] {
            if nowTs < until {
                return true
            }
            quarantinedUntilByMount.removeValue(forKey: mountPath)
        }
        return false
    }

    /// Clears a mount path from quarantine (e.g. upon DiskArbitration mount notification).
    func clearQuarantinedMount(_ mountPath: String) {
        guard !mountPath.isEmpty else { return }
        lock.lock()
        quarantinedUntilByMount.removeValue(forKey: mountPath)
        inFlightMounts.remove(mountPath)
        lock.unlock()
    }

    /// Probes all targets concurrently up to `timeoutSeconds` per target.
    /// Any target exceeding the deadline returns an unresponsive placeholder while remaining
    /// targets complete cleanly within the timeout envelope.
    func probeAll(
        targets: [DriveProbeTarget],
        forceCanary: Bool = false,
        isSystemSleeping: Bool = false,
        nowTs: TimeInterval = Date().timeIntervalSince1970,
        timeoutSeconds: TimeInterval = 3.0,
        telemetry: any DiskTelemetryProvider = IOKitTelemetryProvider.shared
    ) -> [String: DriveProbeResult] {
        guard !targets.isEmpty else { return [:] }

        let resultLock = NSLock()
        var results: [String: DriveProbeResult] = [:]
        let isDarkWake = telemetry.isDarkWakeActive()
        let wallNow = Date().timeIntervalSince1970

        var pendingGroups: [(DriveProbeTarget, DispatchGroup, LockedFlag)] = []
        pendingGroups.reserveCapacity(targets.count)

        for target in targets {
            let neverQuarantine = isProtectedFromQuarantine(mountPath: target.mountPath, isInternal: target.isInternal)

            lock.lock()
            let qUntil = quarantinedUntilByMount[target.mountPath] ?? 0
            let isQuarantined = !neverQuarantine && (wallNow < qUntil)
            if !neverQuarantine && qUntil > 0 && wallNow >= qUntil {
                quarantinedUntilByMount.removeValue(forKey: target.mountPath)
            }
            let alreadyInFlight = !target.mountPath.isEmpty && inFlightMounts.contains(target.mountPath)
            if isQuarantined || alreadyInFlight {
                lock.unlock()
                let emptyFs = FilesystemMountMetrics(isMounted: false, mountPoint: target.mountPath)
                resultLock.lock()
                results[target.driveKey] = DriveProbeResult(
                    driveKey: target.driveKey,
                    fsMetrics: emptyFs,
                    canaryResult: nil,
                    timedOut: alreadyInFlight,
                    isQuarantined: isQuarantined || alreadyInFlight
                )
                resultLock.unlock()
                continue
            }
            if !target.mountPath.isEmpty {
                inFlightMounts.insert(target.mountPath)
            }
            lock.unlock()

            let group = DispatchGroup()
            let didTimeOut = LockedFlag()
            group.enter()
            pendingGroups.append((target, group, didTimeOut))

            probeQueue.addOperation { [weak self] in
                defer {
                    if !target.mountPath.isEmpty {
                        self?.lock.lock()
                        self?.inFlightMounts.remove(target.mountPath)
                        self?.lock.unlock()
                    }
                    group.leave()
                }

                let fsMetrics = telemetry.inspectFilesystem(mountPath: target.mountPath)
                let subpathsStatus = target.requiredSubpaths.isEmpty
                    ? [:]
                    : telemetry.checkSubpaths(
                        mountPoint: fsMetrics.mountPoint.isEmpty ? target.mountPath : fsMetrics.mountPoint,
                        isMounted: fsMetrics.isMounted,
                        requiredSubpaths: target.requiredSubpaths
                    )

                let apfsContainer: ApfsContainerFleetMetrics?
                if target.inspectApfs && fsMetrics.isMounted && fsMetrics.filesystemType.lowercased() == "apfs" {
                    let mnt = fsMetrics.mountPoint.isEmpty ? target.mountPath : fsMetrics.mountPoint
                    apfsContainer = telemetry.inspectApfsContainer(mountPath: mnt)
                } else {
                    apfsContainer = nil
                }

                var canaryRes: CanaryProbeResult? = nil
                let shouldRunCanary = target.runCanary && fsMetrics.isMounted && !fsMetrics.isReadOnly && !isSystemSleeping
                if shouldRunCanary && !(isDarkWake && !target.isInternal) {
                    let mnt = fsMetrics.mountPoint.isEmpty ? target.mountPath : fsMetrics.mountPoint
                    canaryRes = telemetry.runCanaryProbe(targetMount: mnt, force: forceCanary, nowTs: nowTs)
                }

                guard !didTimeOut.get() else { return }

                if !target.mountPath.isEmpty {
                    self?.lock.lock()
                    self?.quarantinedUntilByMount.removeValue(forKey: target.mountPath)
                    self?.lock.unlock()
                }

                resultLock.lock()
                results[target.driveKey] = DriveProbeResult(
                    driveKey: target.driveKey,
                    fsMetrics: fsMetrics,
                    subpathsStatus: subpathsStatus,
                    apfsContainer: apfsContainer,
                    canaryResult: canaryRes,
                    timedOut: false,
                    isQuarantined: false
                )
                resultLock.unlock()
            }
        }

        let overallDeadline = DispatchTime.now() + timeoutSeconds
        for (target, group, didTimeOut) in pendingGroups {
            let waitRes = group.wait(timeout: overallDeadline)
            if waitRes == .timedOut {
                didTimeOut.set(true)
                let shouldQuarantine = !isProtectedFromQuarantine(mountPath: target.mountPath, isInternal: target.isInternal)
                if shouldQuarantine && !target.mountPath.isEmpty {
                    lock.lock()
                    quarantinedUntilByMount[target.mountPath] = Date().timeIntervalSince1970 + Self.quarantineTtlSeconds
                    lock.unlock()
                    ConfigManager.shared.log("CIRCUIT BREAKER (CONC-03): Drive '\(target.driveKey)' at '\(target.mountPath)' hung during I/O probe (> \(String(format: "%.1f", timeoutSeconds))s). Quarantined for \(Int(Self.quarantineTtlSeconds))s.")
                }

                let timeoutFs = FilesystemMountMetrics(isMounted: false, mountPoint: target.mountPath)
                resultLock.lock()
                results[target.driveKey] = DriveProbeResult(
                    driveKey: target.driveKey,
                    fsMetrics: timeoutFs,
                    canaryResult: nil,
                    timedOut: true,
                    isQuarantined: shouldQuarantine
                )
                resultLock.unlock()
            }
        }

        return results
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Bool) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}
