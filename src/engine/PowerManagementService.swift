// ============================================================================
// File: PowerManagementService.swift
// Module: Layer 3 (Telemetry & Engine)
// Purpose: Manages macOS power state assertions and Dark Wake / Power Nap
//          awareness (PWR-01). Suppresses active canary checks during display-off
//          Dark Wake states to preserve external spinning drives, and holds
//          system sleep assertions during active surface scans and volume verification.
// Concurrency: Thread-safe; power assertion IDs tracked under private leaf lock.
// ============================================================================

import Foundation
import IOKit.pwr_mgt

private func powerChangeCallback(
    refCon: UnsafeMutableRawPointer?,
    service: io_service_t,
    messageType: natural_t,
    messageArgument: UnsafeMutableRawPointer?
) {
    guard let refCon = refCon else { return }
    let s = Unmanaged<PowerManagementService>.fromOpaque(refCon).takeUnretainedValue()
    s.handlePowerMessage(messageType: messageType, messageArgument: messageArgument)
}

public final class PowerManagementService {
    public static let shared = PowerManagementService()

    private let lock = NSLock()
    private var activeAssertionCount: Int = 0
    private var currentAssertionID: IOPMAssertionID = 0

    private var rootPowerPort: io_connect_t = 0
    private var notifierRef: io_object_t = 0
    private var notifyPortRef: IONotificationPortRef? = nil

    public var isShieldRegistered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return rootPowerPort != 0
    }

    private init() {}

    /// Registers for macOS kernel sleep/wake notifications to shield external storage (DA-02 / PWR-02).
    public func startPreSleepShield() {
        lock.lock()
        defer { lock.unlock() }
        guard rootPowerPort == 0 else { return }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var thePort: IONotificationPortRef? = nil
        var notifier: io_object_t = 0

        let kernelPort = IORegisterForSystemPower(selfPtr, &thePort, powerChangeCallback, &notifier)
        if kernelPort != 0, let thePort = thePort {
            self.rootPowerPort = kernelPort
            self.notifierRef = notifier
            self.notifyPortRef = thePort
            IONotificationPortSetDispatchQueue(thePort, DispatchQueue.global(qos: .utility))
            ConfigManager.shared.log("Pre-Sleep External Drive Shield registered with macOS IOPMrootDomain.")
        }
    }

    /// Deregisters from macOS kernel sleep/wake notifications (DA-02 / PWR-02).
    public func stopPreSleepShield() {
        lock.lock()
        defer { lock.unlock() }
        guard rootPowerPort != 0 else { return }

        if notifierRef != 0 {
            IODeregisterForSystemPower(&notifierRef)
            notifierRef = 0
        }
        if let thePort = notifyPortRef {
            IONotificationPortDestroy(thePort)
            notifyPortRef = nil
        }
        if rootPowerPort != 0 {
            IOServiceClose(rootPowerPort)
            rootPowerPort = 0
        }
        ConfigManager.shared.log("Pre-Sleep External Drive Shield deregistered from macOS IOPMrootDomain.")
    }

    private let kIOMessageCanSystemSleepConst: natural_t = 0xe0000270
    private let kIOMessageSystemWillSleepConst: natural_t = 0xe0000280
    private let kIOMessageSystemHasPoweredOnConst: natural_t = 0xe0000300

    /// Handles system power state changes delivered from IOPMrootDomain.
    public func handlePowerMessage(messageType: natural_t, messageArgument: UnsafeMutableRawPointer?) {
        let msgId = Int(bitPattern: messageArgument)
        lock.lock()
        let port = rootPowerPort
        lock.unlock()

        switch messageType {
        case kIOMessageSystemWillSleepConst:
            ConfigManager.shared.log("macOS power event: System will sleep (kIOMessageSystemWillSleep).")
            DiskHealthMonitor.shared.noteSystemWillSleep()
            if ConfigManager.shared.currentConfig.preSleepShieldEnabled {
                _ = shieldExternalDrivesBeforeSleep()
            }
            if port != 0 {
                _ = IOAllowPowerChange(port, msgId)
            }

        case kIOMessageCanSystemSleepConst:
            if port != 0 {
                _ = IOAllowPowerChange(port, msgId)
            }

        case kIOMessageSystemHasPoweredOnConst:
            ConfigManager.shared.log("macOS power event: System has powered on (kIOMessageSystemHasPoweredOn).")

        default:
            break
        }
    }

    @discardableResult
    public func shieldExternalDrivesBeforeSleep() -> Int {
        var mountCandidates: [String] = []
        var seen = Set<String>()

        func addCandidate(_ rawPath: String) {
            let norm = (rawPath as NSString).standardizingPath
            guard !norm.isEmpty, norm != "/", !norm.hasPrefix("/System"), !seen.contains(norm) else { return }
            seen.insert(norm)
            mountCandidates.append(norm)
        }

        if let multi = DiskHealthMonitor.shared.currentMultiSnapshot {
            for d in multi.disks where !d.isInternal && d.isMounted {
                addCandidate(d.mountPoint)
            }
        }
        for dev in IOKitTelemetryProvider.shared.listAllDevices(maxCount: 32) where dev.found && !dev.isInternal {
            let bsd = cStringToSwift(dev.bsdName)
            if !bsd.isEmpty, let mnt = IOKitTelemetryProvider.shared.findMountPoint(forBsdName: bsd) {
                addCandidate(mnt)
            }
        }

        let totalDeadline = ProcessInfo.processInfo.systemUptime + 18.0
        var unmountedCount = 0
        for mount in mountCandidates {
            if ParallelDriveProber.shared.isMountQuarantined(mount) {
                ConfigManager.shared.log("Pre-Sleep Shield: Skipping quarantined mount '\(mount)'.")
                continue
            }
            let remaining = totalDeadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0.5 {
                ConfigManager.shared.log("Pre-Sleep Shield: Reached 18.0s cumulative deadline; skipping remaining unmounts to protect IOAllowPowerChange budget.")
                break
            }
            let perDriveTimeout = min(6.0, remaining)
            ConfigManager.shared.log("Pre-Sleep Shield: Safely unmounting external volume '\(mount)'...")
            let res = OpenFileBlockerInspector.shared.unmountVolume(mountPath: mount, force: false, timeoutSeconds: perDriveTimeout)
            if res.exitCode == 0 {
                ConfigManager.shared.log("Pre-Sleep Shield: Safely unmounted '\(mount)'.")
                unmountedCount += 1
            } else {
                ConfigManager.shared.log("Pre-Sleep Shield: Unmount failed for '\(mount)': \(res.stderr)")
            }
        }
        return unmountedCount
    }

    /// Checks if the Mac is currently in Dark Wake (display asleep during Power Nap / background tasks).
    public func isDarkWakeActive() -> Bool {
        return DiskIsDarkWakeActive() != 0
    }

    /// Acquires an IOPMAssertion preventing idle system sleep while executing the supplied closure.
    ///
    /// - Parameters:
    ///   - reason: Human-readable diagnostic description (e.g. "DiskHealthMonitor Surface Scan").
    ///   - work: The blocking or synchronous operation to execute.
    /// - Returns: The result of the `work` closure.
    public func withPreventIdleSleepAssertion<T>(reason: String, _ work: () throws -> T) rethrows -> T {
        acquireAssertion(reason: reason)
        defer {
            releaseAssertion()
        }
        return try work()
    }

    /// Acquires an IOPMAssertion preventing idle system sleep asynchronously.
    public func acquireAssertion(reason: String) {
        lock.lock()
        defer { lock.unlock() }

        if activeAssertionCount == 0 {
            var assertionID: IOPMAssertionID = 0
            let cfReason = reason as CFString
            let returnCode = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                cfReason,
                &assertionID
            )
            if returnCode == kIOReturnSuccess {
                self.currentAssertionID = assertionID
                self.activeAssertionCount = 1
            }
        } else {
            activeAssertionCount += 1
        }
    }

    /// Releases an existing IOPMAssertion.
    public func releaseAssertion() {
        lock.lock()
        defer { lock.unlock() }

        guard activeAssertionCount > 0 else { return }
        activeAssertionCount -= 1

        if activeAssertionCount == 0 && currentAssertionID != 0 {
            IOPMAssertionRelease(currentAssertionID)
            currentAssertionID = 0
        }
    }
}
