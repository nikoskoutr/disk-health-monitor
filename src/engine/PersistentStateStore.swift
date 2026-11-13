// ============================================================================
// File: PersistentStateStore.swift
// Module: Layer 3 (Telemetry & Domain Engine)
// Purpose: Atomic inter-process persistent state storage (state.json),
//          cross-process flock locking, migration, baseline anchoring/reset,
//          and latest_status.json serialization.
// Concurrency: Called under DiskHealthMonitor engineLock with state.lock flock.
// ============================================================================

import Foundation
import Darwin

/// Encapsulates persistent state loading, migration, atomic saving, and per-drive baseline management.
enum PersistentStateStore {
    static let prettyJSONEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    /// Loads `state.json` and runs idempotent migrations for stale verification/alert flags.
    static func loadState() -> DiskPersistentState {
        let path = ConfigManager.shared.stateFilePath
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           var decoded = try? JSONDecoder().decode(DiskPersistentState.self, from: data) {
            var migrated = false
            for (k, var d) in decoded.drives {
                if !d.lastVerifyOk && VolumeVerifierService.isNonCorruptionVerifyFailure(d.lastVerifyResult) {
                    d.lastVerifyOk = true
                    d.lastVerifyResult = "Skipped: Requires administrator privileges (-69863)"
                    if d.lastOverallSeverity == HealthSeverity.critical.rawValue {
                        d.lastOverallSeverity = HealthSeverity.healthy.rawValue
                    }
                    decoded.drives[k] = d
                    migrated = true
                }
                if d.lastVerifyOk {
                    let verifyAlertKey = "\(k):VOLUME_VERIFY_FAILED"
                    if decoded.lastAlertTimestampByCode.removeValue(forKey: verifyAlertKey) != nil {
                        migrated = true
                    }
                }
                if d.lastVerifyResult == "Not run yet" && d.lastVerifyTimestamp > 0 {
                    d.lastVerifyTimestamp = 0
                    decoded.drives[k] = d
                    migrated = true
                }
            }
            if decoded.lastAlertTimestampByCode.removeValue(forKey: "VOLUME_VERIFY_FAILED") != nil {
                migrated = true
            }
            if migrated {
                if decoded.lastOverallSeverity == HealthSeverity.critical.rawValue &&
                   !decoded.drives.values.contains(where: { $0.lastOverallSeverity == HealthSeverity.critical.rawValue }) {
                    decoded.lastOverallSeverity = HealthSeverity.healthy.rawValue
                }
                if let outData = try? prettyJSONEncoder.encode(decoded) {
                    _ = AtomicFileWriter.writeRestricted(data: outData, toPath: path, permissions: 0o600)
                }
            }
            return decoded
        }
        return DiskPersistentState()
    }

    /// Saves `state` to `state.json` under `flock` on `state.lock`, skipping disk I/O if clean.
    static func saveState(
        _ state: DiskPersistentState,
        lastSavedState: inout DiskPersistentState?,
        force: Bool = false
    ) {
        let path = ConfigManager.shared.stateFilePath
        let lockPath = "\(ConfigManager.shared.stateDir)/state.lock"
        let lockFd = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if lockFd >= 0 {
            _ = flock(lockFd, LOCK_EX)
        }
        defer {
            if lockFd >= 0 {
                _ = flock(lockFd, LOCK_UN)
                close(lockFd)
            }
        }

        if !force, let last = lastSavedState, last == state, FileManager.default.fileExists(atPath: path) {
            return
        }
        if let data = try? prettyJSONEncoder.encode(state),
           AtomicFileWriter.writeRestricted(data: data, toPath: path, permissions: 0o600) {
            lastSavedState = state
        }
    }

    /// Persists `latest_status.json` using single-disk format for 1 drive or multi-disk fleet format otherwise.
    static func saveLatestStatus(multi: MultiDiskHealthSnapshot, primary: DiskHealthSnapshot) {
        let payloadData: Data?
        if multi.disks.count > 1 {
            payloadData = try? prettyJSONEncoder.encode(multi)
        } else {
            payloadData = try? prettyJSONEncoder.encode(primary)
        }
        if let jsonData = payloadData {
            _ = AtomicFileWriter.writeRestricted(data: jsonData, toPath: ConfigManager.shared.latestJsonPath, permissions: 0o600)
        }
    }

    /// Anchors uninitialized baselines and re-baselines counters that decreased across reboots/replugs.
    static func synchronizeBaselines(
        driveState: inout DriveBaselineState,
        hardware hw: DiskHardwareMetrics,
        filesystem fsMetrics: FilesystemMountMetrics
    ) {
        let tempC = Int(hw.temperatureCelsius)
        if (hw.smartValid || tempC > 0) && tempC > driveState.peakTemperatureCelsius {
            driveState.peakTemperatureCelsius = tempC
        }
        if hw.smartValid {
            if driveState.baselineUnsafeShutdowns == nil { driveState.baselineUnsafeShutdowns = hw.unsafeShutdowns }
            if driveState.baselineMediaErrors == nil { driveState.baselineMediaErrors = 0 }
            if driveState.baselineErrorLogEntries == nil { driveState.baselineErrorLogEntries = hw.errorInfoLogEntries }

            if let prevMedia = driveState.baselineMediaErrors, hw.mediaErrors < prevMedia {
                driveState.baselineMediaErrors = hw.mediaErrors
            }
            if let prevLog = driveState.baselineErrorLogEntries, hw.errorInfoLogEntries < prevLog {
                driveState.baselineErrorLogEntries = hw.errorInfoLogEntries
            }
        }
        if hw.statsValid {
            if driveState.baselineIoReadErrors == nil { driveState.baselineIoReadErrors = 0 }
            if driveState.baselineIoWriteErrors == nil { driveState.baselineIoWriteErrors = 0 }
            if driveState.baselineIoReadRetries == nil { driveState.baselineIoReadRetries = hw.retriesRead }
            if driveState.baselineIoWriteRetries == nil { driveState.baselineIoWriteRetries = hw.retriesWritten }

            if let prevR = driveState.baselineIoReadErrors, hw.errorsRead < prevR {
                driveState.baselineIoReadErrors = hw.errorsRead
            }
            if let prevW = driveState.baselineIoWriteErrors, hw.errorsWritten < prevW {
                driveState.baselineIoWriteErrors = hw.errorsWritten
            }
            if let prevRetR = driveState.baselineIoReadRetries, hw.retriesRead < prevRetR {
                driveState.baselineIoReadRetries = hw.retriesRead
            }
            if let prevRetW = driveState.baselineIoWriteRetries, hw.retriesWritten < prevRetW {
                driveState.baselineIoWriteRetries = hw.retriesWritten
            }
        }

        if driveState.baselineBusErrors == nil {
            driveState.baselineBusErrors = hw.busErrorCount
        } else if let prevBusErr = driveState.baselineBusErrors, hw.busErrorCount < prevBusErr {
            driveState.baselineBusErrors = hw.busErrorCount
        }
        if driveState.baselineBusResets == nil {
            driveState.baselineBusResets = hw.busResetCount
        } else if let prevBusRst = driveState.baselineBusResets, hw.busResetCount < prevBusRst {
            driveState.baselineBusResets = hw.busResetCount
        }

        if fsMetrics.isMounted && !fsMetrics.isReadOnly {
            driveState.wasWritable = true
        }
    }

    /// Resets per-drive error baselines, cooldowns, and alert severity counters across the active fleet.
    static func resetBaselines(in state: inout DiskPersistentState, activeSnapshots: [DiskHealthSnapshot]) {
        let oldTarget = state.monitoredTarget
        let oldDaily = state.dailySummaryEnabled
        if !activeSnapshots.isEmpty {
            for snap in activeSnapshots {
                state.updateDriveState(key: snap.driveKey) { d in
                    d.bsdName = snap.bsdName
                    d.serialNumber = snap.serialNumber
                    d.peakTemperatureCelsius = snap.temperatureCelsius
                    d.baselineUnsafeShutdowns = snap.unsafeShutdowns
                    d.baselineMediaErrors = snap.mediaErrors
                    d.baselineErrorLogEntries = snap.errorInfoLogEntries
                    d.baselineIoReadErrors = snap.errorsRead
                    d.baselineIoWriteErrors = snap.errorsWritten
                    d.baselineIoReadRetries = snap.retriesRead
                    d.baselineIoWriteRetries = snap.retriesWritten
                    d.baselineBusErrors = snap.busErrorCount
                    d.baselineBusResets = snap.busResetCount
                }
            }
        } else {
            for k in Array(state.drives.keys) {
                state.updateDriveState(key: k) { d in
                    d.baselineUnsafeShutdowns = d.baselineUnsafeShutdowns ?? 0
                    d.baselineMediaErrors = d.baselineMediaErrors ?? 0
                    d.baselineErrorLogEntries = d.baselineErrorLogEntries ?? 0
                    d.baselineIoReadErrors = d.baselineIoReadErrors ?? 0
                    d.baselineIoWriteErrors = d.baselineIoWriteErrors ?? 0
                    d.baselineIoReadRetries = d.baselineIoReadRetries ?? 0
                    d.baselineIoWriteRetries = d.baselineIoWriteRetries ?? 0
                    d.baselineBusErrors = d.baselineBusErrors ?? 0
                    d.baselineBusResets = d.baselineBusResets ?? 0
                }
            }
            state.monitoredTarget = oldTarget
            state.dailySummaryEnabled = oldDaily
        }
        for k in Array(state.drives.keys) {
            state.updateDriveState(key: k) {
                $0.lastVerifyOk = true
                if !$0.lastVerifyResult.starts(with: "Verified OK") {
                    $0.lastVerifyResult = "Not run yet"
                    $0.lastVerifyTimestamp = 0
                }
                $0.lastOverallSeverity = HealthSeverity.healthy.rawValue
                $0.consecutiveHealthyPolls = 0
                $0.consecutiveUnhealthyPolls = 0
                $0.lastNotifiedSeverity = HealthSeverity.healthy.rawValue
            }
        }
        state.lastOverallSeverity = HealthSeverity.healthy.rawValue
        state.lastAlertTimestampByCode.removeAll()
    }
}
