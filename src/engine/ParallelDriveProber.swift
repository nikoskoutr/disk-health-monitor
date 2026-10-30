// ============================================================================
// File: ParallelDriveProber.swift
// Module: Layer 3 (Telemetry & Engine)
// Purpose: Lock-split bounded parallel drive prober with 3-second circuit breaker (CONC-03).
//          Decouples blocking VFS and canary filesystem I/O from engineLock.
//          Quarantines unresponsive external controllers in kernel D-state.
// Concurrency: Thread-safe; bounded worker pool (max concurrency 4), private leaf lock.
// ============================================================================

import Foundation

struct DriveProbeTarget: Sendable {
    let driveKey: String
    let mountPath: String
    let isInternal: Bool
    let runCanary: Bool

    init(driveKey: String, mountPath: String, isInternal: Bool, runCanary: Bool) {
        self.driveKey = driveKey
        self.mountPath = mountPath
        self.isInternal = isInternal
        self.runCanary = runCanary
    }
}

struct DriveProbeResult: Sendable {
    let driveKey: String
    let fsMetrics: FilesystemMountMetrics?
    let canaryResult: CanaryProbeResult?
    let timedOut: Bool
    let isQuarantined: Bool

    init(
        driveKey: String,
        fsMetrics: FilesystemMountMetrics?,
        canaryResult: CanaryProbeResult?,
        timedOut: Bool,
        isQuarantined: Bool = false
    ) {
        self.driveKey = driveKey
        self.fsMetrics = fsMetrics
        self.canaryResult = canaryResult
        self.timedOut = timedOut
        self.isQuarantined = isQuarantined
    }
}

final class ParallelDriveProber {
    static let shared = ParallelDriveProber()

    private let stateLock = NSLock()
    private var stalledMountPaths = Set<String>()
    private let concurrencyGate = DispatchSemaphore(value: 4)
    private let workerQueue = DispatchQueue(label: "io.github.disk-health.prober.pool", attributes: .concurrent)

    private init() {}

    /// Checks if a mount path is currently quarantined due to a previous kernel I/O timeout.
    func isMountQuarantined(_ mountPath: String) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stalledMountPaths.contains(mountPath)
    }

    /// Clears quarantined state for an unmounted or replugged volume.
    func clearQuarantinedMount(_ mountPath: String) {
        stateLock.lock()
        defer { stateLock.unlock() }
        stalledMountPaths.remove(mountPath)
    }

    /// Probes multiple filesystem targets concurrently with a bounded pool and hard timeout.
    func probeAll(
        targets: [DriveProbeTarget],
        timeoutSeconds: TimeInterval = 3.0,
        telemetry: DiskTelemetryProvider = IOKitTelemetryProvider.shared
    ) -> [String: DriveProbeResult] {
        let group = DispatchGroup()
        let resultsLock = NSLock()
        var results: [String: DriveProbeResult] = [:]

        let isDarkWake = PowerManagementService.shared.isDarkWakeActive()

        for target in targets {
            guard !target.mountPath.isEmpty else { continue }

            stateLock.lock()
            let isStalled = stalledMountPaths.contains(target.mountPath)
            stateLock.unlock()

            if isStalled {
                resultsLock.lock()
                results[target.driveKey] = DriveProbeResult(
                    driveKey: target.driveKey,
                    fsMetrics: nil,
                    canaryResult: CanaryProbeResult(
                        ok: false,
                        latencyMs: timeoutSeconds * 1000.0,
                        error: "CONTROLLER_UNRESPONSIVE_CIRCUIT_OPEN"
                    ),
                    timedOut: true,
                    isQuarantined: true
                )
                resultsLock.unlock()
                continue
            }

            group.enter()
            workerQueue.async {
                self.concurrencyGate.wait()
                defer {
                    self.concurrencyGate.signal()
                    group.leave()
                }

                let innerDone = DispatchSemaphore(value: 0)
                var fsOut: FilesystemMountMetrics?
                var canaryOut: CanaryProbeResult?

                DispatchQueue.global(qos: .utility).async {
                    fsOut = telemetry.inspectFilesystem(mountPath: target.mountPath)

                    // Skip active write canary on external drives during Dark Wake / Power Nap
                    let shouldSkipCanaryForDarkWake = isDarkWake && !target.isInternal
                    if target.runCanary && !shouldSkipCanaryForDarkWake {
                        canaryOut = CanaryProbeService.shared.runCanaryCheck(targetMount: target.mountPath, force: false)
                    }

                    self.stateLock.lock()
                    self.stalledMountPaths.remove(target.mountPath)
                    self.stateLock.unlock()

                    innerDone.signal()
                }

                let waitStatus = innerDone.wait(timeout: .now() + timeoutSeconds)
                resultsLock.lock()
                if waitStatus == .timedOut {
                    self.stateLock.lock()
                    self.stalledMountPaths.insert(target.mountPath)
                    self.stateLock.unlock()

                    results[target.driveKey] = DriveProbeResult(
                        driveKey: target.driveKey,
                        fsMetrics: nil,
                        canaryResult: CanaryProbeResult(
                            ok: false,
                            latencyMs: timeoutSeconds * 1000.0,
                            error: "CONTROLLER_IO_TIMEOUT_\(Int(timeoutSeconds * 1000))MS"
                        ),
                        timedOut: true,
                        isQuarantined: true
                    )
                } else {
                    results[target.driveKey] = DriveProbeResult(
                        driveKey: target.driveKey,
                        fsMetrics: fsOut,
                        canaryResult: canaryOut,
                        timedOut: false,
                        isQuarantined: false
                    )
                }
                resultsLock.unlock()
            }
        }

        group.wait()
        return results
    }
}
