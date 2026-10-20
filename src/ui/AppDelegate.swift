import AppKit
import SwiftUI
import Darwin
import Combine

// MARK: - AppKit Menu Bar Controller & Dynamic Drive Selection

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var pollTimer: Timer?
    private var currentPollInterval: TimeInterval = 30.0
    private var configCancellable: AnyCancellable?
    private var dailyDigestItem: NSMenuItem!
    private var selectDiskMenu: NSMenu!
    private var selectDiskMenuItem: NSMenuItem!
    private var cachedDevices: [DiskHardwareMetrics] = []
    private var cachedMounts: [(path: String, name: String)] = []
    private let cacheLock = NSLock()
    private var mountDebounceWorkItem: DispatchWorkItem?
    private var wakeWorkItem: DispatchWorkItem?
    private var configRefreshWorkItem: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Set application icon from bundled AppIcon.icns or assets fallback
        let candidateIconPaths = [
            Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
            "assets/AppIcon.icns",
            "\(Bundle.main.bundleURL.deletingLastPathComponent().path)/assets/AppIcon.icns"
        ]
        for p in candidateIconPaths {
            if let p = p, let iconImg = NSImage(contentsOfFile: p) {
                NSApp.applicationIconImage = iconImg
                break
            }
        }

        setupMainMenuForShortcuts()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setupMenu()

        // Observe macOS volume mount / unmount and system sleep / wake
        let wsCenter = NSWorkspace.shared.notificationCenter
        wsCenter.addObserver(self, selector: #selector(volumeMountChanged(_:)), name: NSWorkspace.didMountNotification, object: nil)
        wsCenter.addObserver(self, selector: #selector(volumeMountChanged(_:)), name: NSWorkspace.didUnmountNotification, object: nil)
        wsCenter.addObserver(self, selector: #selector(systemWillSleep(_:)), name: NSWorkspace.willSleepNotification, object: nil)
        wsCenter.addObserver(self, selector: #selector(systemDidWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)

        // Initial check
        refreshHealth(forceCanary: true)

        // Dynamic timer polling
        schedulePollingTimer(interval: ConfigManager.shared.currentConfig.pollIntervalSeconds)

        configCancellable = ConfigManager.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                let newInterval = ConfigManager.shared.currentConfig.pollIntervalSeconds
                if abs(newInterval - self.currentPollInterval) > 0.01 {
                    self.schedulePollingTimer(interval: newInterval)
                }
                self.configRefreshWorkItem?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self = self, !DiskHealthMonitor.shared.isSystemSleeping else { return }
                    self.refreshHealth(forceCanary: false)
                }
                self.configRefreshWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
            }

        ConfigManager.shared.log("Disk Health Monitor Menu Bar App launched.")
    }

    private func schedulePollingTimer(interval: TimeInterval) {
        let safeInterval = max(5.0, interval)
        pollTimer?.invalidate()
        currentPollInterval = safeInterval
        let timer = Timer.scheduledTimer(withTimeInterval: safeInterval, repeats: true) { [weak self] _ in
            self?.refreshHealth(forceCanary: false)
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func setupMainMenuForShortcuts() {
        let mainMenu = NSMenu()

        // App Menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit Disk Health Monitor", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit Menu (Essential for Cut/Copy/Paste/Select All in text fields)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Window Menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func setupMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let hostingItem = NSMenuItem()
        let dashboardView = DashboardMenuView(monitor: DiskHealthMonitor.shared)
        let hostingView = NSHostingView(rootView: dashboardView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 385, height: 310)
        hostingItem.view = hostingView
        menu.addItem(hostingItem)

        menu.addItem(NSMenuItem.separator())

        // Dynamic Disk Selection Submenu
        selectDiskMenuItem = NSMenuItem(title: "Select Monitored Disk", action: nil, keyEquivalent: "")
        selectDiskMenu = NSMenu()
        selectDiskMenuItem.submenu = selectDiskMenu
        menu.addItem(selectDiskMenuItem)

        menu.addItem(NSMenuItem.separator())

        let checkNowItem = NSMenuItem(title: "Run Deep Health & Canary Check Now", action: #selector(runCheckNow), keyEquivalent: "r")
        checkNowItem.target = self
        menu.addItem(checkNowItem)

        let verifyItem = NSMenuItem(title: "Verify Volume File System (diskutil)...", action: #selector(verifyVolumeNow), keyEquivalent: "v")
        verifyItem.target = self
        menu.addItem(verifyItem)

        let smartInspectorItem = NSMenuItem(title: "Inspect Raw S.M.A.R.T. & Hardware Counters...", action: #selector(openSmartInspector), keyEquivalent: "i")
        smartInspectorItem.target = self
        menu.addItem(smartInspectorItem)

        let telegramReportItem = NSMenuItem(title: "Send Status Report to Telegram Now", action: #selector(sendTelegramReportNow), keyEquivalent: "t")
        telegramReportItem.target = self
        menu.addItem(telegramReportItem)

        dailyDigestItem = NSMenuItem(title: "Daily Telegram Health Digest (09:00)", action: #selector(toggleDailyDigest), keyEquivalent: "")
        dailyDigestItem.target = self
        dailyDigestItem.state = DiskHealthMonitor.shared.dailySummaryEnabled ? .on : .off
        menu.addItem(dailyDigestItem)

        menu.addItem(NSMenuItem.separator())

        let exportDiagItem = NSMenuItem(title: "Export Diagnostic Report (JSON)...", action: #selector(exportDiagnosticReportAction), keyEquivalent: "e")
        exportDiagItem.target = self
        menu.addItem(exportDiagItem)

        let exportHtmlItem = NSMenuItem(title: "Export HTML Health Report (RMA)...", action: #selector(exportHtmlReportAction), keyEquivalent: "h")
        exportHtmlItem.target = self
        menu.addItem(exportHtmlItem)

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let openVolumeItem = NSMenuItem(title: "Open Volume in Finder", action: #selector(openVolumeInFinder), keyEquivalent: "o")
        openVolumeItem.target = self
        menu.addItem(openVolumeItem)

        let openLogItem = NSMenuItem(title: "View Health Monitor Log", action: #selector(openHealthLog), keyEquivalent: "l")
        openLogItem.target = self
        menu.addItem(openLogItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Disk Health Monitor", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    func populateSelectDiskMenu() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.populateSelectDiskMenu()
            }
            return
        }
        guard selectDiskMenu != nil else { return }

        selectDiskMenu.removeAllItems()

        cacheLock.lock()
        var devices = cachedDevices
        var mounts = cachedMounts
        cacheLock.unlock()

        if devices.isEmpty && mounts.isEmpty {
            updateDiskCache()
            cacheLock.lock()
            devices = cachedDevices
            mounts = cachedMounts
            cacheLock.unlock()
        }

        let currentActive = DiskHealthMonitor.shared.currentSnapshot?.bsdName ?? ""
        let currentMount = DiskHealthMonitor.shared.currentSnapshot?.mountPoint ?? ""
        let cfg = ConfigManager.shared.currentConfig

        // Auto option
        let autoItem = NSMenuItem(title: "Auto-detect First External Volume", action: #selector(selectDiskTarget(_:)), keyEquivalent: "")
        autoItem.target = self
        autoItem.representedObject = "auto"
        if cfg.targetVolumePath == nil && cfg.targetDeviceQuery == nil {
            autoItem.state = .on
        }
        selectDiskMenu.addItem(autoItem)
        selectDiskMenu.addItem(NSMenuItem.separator())

        // Physical Disks
        for d in devices {
            let prod = cStringToSwift(d.productName)
            let vendor = cStringToSwift(d.vendorName)
            let bsd = cStringToSwift(d.bsdName)
            let serial = cStringToSwift(d.serialNumber)
            let bus = cStringToSwift(d.interconnectType)
            let label = "\(vendor.isEmpty ? "" : vendor + " ")\(prod) (\(bsd), \(bus))"

            let item = NSMenuItem(title: label, action: #selector(selectDiskTarget(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = bsd
            if (cfg.targetDeviceQuery == bsd || (!serial.isEmpty && cfg.targetDeviceQuery == serial)) ||
               (cfg.targetVolumePath == nil && currentActive == bsd) {
                item.state = .on
            }
            selectDiskMenu.addItem(item)
        }

        // Mounted Volumes in /Volumes
        if !mounts.isEmpty {
            selectDiskMenu.addItem(NSMenuItem.separator())
            let sectionItem = NSMenuItem(title: "Mounted Volumes:", action: nil, keyEquivalent: "")
            sectionItem.isEnabled = false
            selectDiskMenu.addItem(sectionItem)

            for m in mounts {
                let item = NSMenuItem(title: "  📂 \(m.name)", action: #selector(selectDiskTarget(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = m.path
                if cfg.targetVolumePath == m.path ||
                   (cfg.targetVolumePath == nil && cfg.targetDeviceQuery == nil && currentMount == m.path) {
                    item.state = .on
                }
                selectDiskMenu.addItem(item)
            }
        }

        // Custom / Offline configured target
        if let customVol = cfg.targetVolumePath, !customVol.isEmpty,
           !mounts.contains(where: { $0.path == customVol }) {
            selectDiskMenu.addItem(NSMenuItem.separator())
            let item = NSMenuItem(title: "📌 Configured Volume (\(customVol))", action: #selector(selectDiskTarget(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = customVol
            item.state = .on
            selectDiskMenu.addItem(item)
        }
        if let customDev = cfg.targetDeviceQuery, !customDev.isEmpty,
           !devices.contains(where: { cStringToSwift($0.bsdName) == customDev || (!cStringToSwift($0.serialNumber).isEmpty && cStringToSwift($0.serialNumber) == customDev) }) {
            selectDiskMenu.addItem(NSMenuItem.separator())
            let item = NSMenuItem(title: "📌 Configured Device (\(customDev))", action: #selector(selectDiskTarget(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = customDev
            item.state = .on
            selectDiskMenu.addItem(item)
        }
    }

    @objc private func selectDiskTarget(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? String else { return }
        ConfigManager.shared.log("User selected disk target: \(target)")
        if target == "auto" {
            DiskHealthMonitor.shared.setMonitoredTarget(volumePath: nil, deviceQuery: nil)
        } else if target.hasPrefix("/") {
            DiskHealthMonitor.shared.setMonitoredTarget(volumePath: target, deviceQuery: nil)
        } else {
            DiskHealthMonitor.shared.setMonitoredTarget(volumePath: nil, deviceQuery: target)
        }
        refreshHealth(forceCanary: true)
    }

    func testingSetSelectDiskMenu(_ menu: NSMenu) {
        self.selectDiskMenu = menu
    }

    var testingGetSelectDiskMenu: NSMenu? {
        return self.selectDiskMenu
    }

    func menuWillOpen(_ menu: NSMenu) {
        dailyDigestItem.state = DiskHealthMonitor.shared.dailySummaryEnabled ? .on : .off
        populateSelectDiskMenu()
        refreshHealth(forceCanary: false)
        if let hostingView = menu.items.first?.view {
            hostingView.invalidateIntrinsicContentSize()
            let fitting = hostingView.fittingSize
            hostingView.frame = NSRect(x: 0, y: 0, width: 385, height: max(310, fitting.height))
        }
    }

    static func shouldProcessVolumeNotification(volumePath: String?) -> Bool {
        guard let path = volumePath, !path.isEmpty else { return true }
        if path == "/Volumes/Recovery" ||
           path.hasPrefix("/System/Volumes/") ||
           path.hasPrefix("/private/") ||
           path.hasPrefix("/dev/") ||
           path.contains(".timemachine") ||
           path.contains("com.apple.TimeMachine.localsnapshots") {
            return false
        }
        return path == "/" || path.hasPrefix("/Volumes/")
    }

    @objc private func volumeMountChanged(_ note: Notification) {
        guard !DiskHealthMonitor.shared.isSystemSleeping else {
            ConfigManager.shared.log("Ignoring dark-wake volume mount event while system is sleeping: \(note.name.rawValue)")
            return
        }
        let volumeURL = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
        let volumePath = volumeURL?.path
        guard AppDelegate.shouldProcessVolumeNotification(volumePath: volumePath) else {
            return
        }
        mountDebounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, !DiskHealthMonitor.shared.isSystemSleeping else { return }
            let pathSuffix = volumePath.map { " [\($0)]" } ?? ""
            ConfigManager.shared.log("Processing settled volume mount change (\(note.name.rawValue)\(pathSuffix))")
            self.refreshHealth(forceCanary: true)
        }
        mountDebounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    @objc private func systemWillSleep(_ note: Notification) {
        pollTimer?.invalidate()
        mountDebounceWorkItem?.cancel()
        wakeWorkItem?.cancel()
        configRefreshWorkItem?.cancel()
        DiskHealthMonitor.shared.noteSystemWillSleep()
    }

    @objc private func systemDidWake(_ note: Notification) {
        DiskHealthMonitor.shared.noteSystemDidWake()
        wakeWorkItem?.cancel()
        // Wait 8 seconds for external USB/Thunderbolt buses to re-enumerate before polling
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, !DiskHealthMonitor.shared.isSystemSleeping else { return }
            self.refreshHealth(forceCanary: false)
            self.schedulePollingTimer(interval: ConfigManager.shared.currentConfig.pollIntervalSeconds)
        }
        wakeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0, execute: work)
    }

    private func updateDiskCache() {
        var devices = [DiskHardwareMetrics](repeating: DiskHardwareMetrics(), count: 16)
        let count = DiskListAllDevices(&devices, 16)
        var mounts: [(path: String, name: String)] = []

        let numMounts = getfsstat(nil, 0, MNT_NOWAIT)
        if numMounts > 0 {
            let allocCount = Int(numMounts) + 4
            var fsList = Array<Darwin.statfs>(repeating: Darwin.statfs(), count: allocCount)
            let mCount = getfsstat(&fsList, Int32(MemoryLayout<Darwin.statfs>.size * allocCount), MNT_NOWAIT)
            if mCount > 0 {
                for i in 0..<min(Int(mCount), allocCount) {
                    let volPath = cStringToSwift(fsList[i].f_mntonname)
                    let flags = UInt32(fsList[i].f_flags)
                    let isLocal = (flags & UInt32(MNT_LOCAL)) != 0
                    if isLocal && (volPath.hasPrefix("/Volumes/") || volPath == "/") {
                        let displayName = volPath == "/" ? "Macintosh HD (/)" : (volPath as NSString).lastPathComponent
                        mounts.append((path: volPath, name: displayName))
                    }
                }
            }
        }

        cacheLock.lock()
        cachedDevices = Array(devices.prefix(Int(count)))
        cachedMounts = mounts
        cacheLock.unlock()
    }

    private func refreshHealth(forceCanary: Bool) {
        DispatchQueue.global(qos: .utility).async {
            self.updateDiskCache()
            let snap = DiskHealthMonitor.shared.evaluateHealth(forceCanary: forceCanary, allowNotifications: true)
            DispatchQueue.main.async {
                self.updateStatusBarButton(with: snap)
                self.populateSelectDiskMenu()
                if let hostingView = self.statusItem.menu?.items.first?.view {
                    hostingView.invalidateIntrinsicContentSize()
                    let fitting = hostingView.fittingSize
                    hostingView.frame = NSRect(x: 0, y: 0, width: 385, height: max(310, fitting.height))
                }
            }
        }
    }

    private func updateStatusBarButton(with snap: DiskHealthSnapshot) {
        guard let button = statusItem.button else { return }

        let symbolName: String
        switch snap.overallSeverity {
        case .healthy:
            symbolName = "externaldrive.fill.badge.checkmark"
        case .warning:
            symbolName = "externaldrive.trianglebadge.exclamationmark"
        case .critical:
            symbolName = "externaldrive.fill.badge.xmark"
        }

        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Disk Health") {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            let configured = img.withSymbolConfiguration(config) ?? img
            configured.isTemplate = (snap.overallSeverity == .healthy)
            button.image = configured
            button.imagePosition = .imageLeading
        }

        let shortName = snap.mountPoint.isEmpty ? (snap.bsdName.isEmpty ? "Disk" : snap.bsdName) : (snap.mountPoint as NSString).lastPathComponent
        if !snap.isMounted || !snap.hardwareFound {
            button.title = " \(shortName) ❌"
        } else if snap.overallSeverity == .critical {
            button.title = " \(shortName) 🚨 \(snap.temperatureCelsius)°C"
        } else if snap.overallSeverity == .warning {
            button.title = " \(shortName) ⚠️ \(snap.temperatureCelsius)°C"
        } else if snap.smartValid {
            button.title = " \(shortName) \(snap.temperatureCelsius)°C"
        } else {
            button.title = " \(shortName) OK"
        }
    }

    @objc func openSettings() {
        statusItem.menu?.cancelTracking()
        SettingsWindowController.shared.showSettings()
    }

    @objc func openSmartInspector() {
        statusItem.menu?.cancelTracking()
        SettingsWindowController.shared.showSettings(tab: 3)
    }

    @objc private func exportDiagnosticReportAction() {
        if let path = DiagnosticExporter.shared.saveDiagnosticReportToFile() {
            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: ConfigManager.shared.logsDir)
        }
    }

    @objc private func exportHtmlReportAction() {
        if let path = DiagnosticExporter.shared.saveDiagnosticReportHTMLToFile() {
            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: ConfigManager.shared.logsDir)
        }
    }

    @objc private func runCheckNow() {
        refreshHealth(forceCanary: true)
    }

    @objc private func verifyVolumeNow() {
        DiskHealthMonitor.shared.runVolumeVerification(sendTelegram: true)
    }

    @objc private func sendTelegramReportNow() {
        DispatchQueue.global(qos: .userInitiated).async {
            let snap = DiskHealthMonitor.shared.evaluateHealth(forceCanary: true, allowNotifications: false)
            let html = TelegramNotifier.shared.formatReportHTML(snapshot: snap, title: "On-Demand Disk Health Report")
            TelegramNotifier.shared.sendMessage(htmlText: html, disableNotification: false)
        }
    }

    @objc private func toggleDailyDigest() {
        let next = !DiskHealthMonitor.shared.dailySummaryEnabled
        DiskHealthMonitor.shared.dailySummaryEnabled = next
        dailyDigestItem.state = next ? .on : .off
    }

    @objc private func openVolumeInFinder() {
        let path = DiskHealthMonitor.shared.currentSnapshot?.mountPoint.isEmpty == false
            ? DiskHealthMonitor.shared.currentSnapshot!.mountPoint
            : "/"
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func openHealthLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: ConfigManager.shared.logFilePath))
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        SingleInstanceLock.shared.release()
    }
}
