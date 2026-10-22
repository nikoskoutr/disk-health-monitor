import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Darwin

// MARK: - Native macOS Settings Window Controller & ViewModel (Cmd+,)

final class SettingsViewModel: ObservableObject {
    @Published var selectedTab: Int = 0
    @Published var availableDisks: [(id: String, name: String)] = []
    @Published var launchAgentInstalled: Bool = false
    @Published var isUpdatingLaunchAgent: Bool = false
    @Published var botToken: String = ""
    @Published var showToken: Bool = false
    @Published var webhookUrl: String = ""
    @Published var showWebhookUrl: Bool = false
    @Published var isTestingTelegram: Bool = false
    @Published var testResult: String? = nil
    @Published var testSuccess: Bool = false
    @Published var isTestingWebhook: Bool = false
    @Published var webhookTestResult: String? = nil
    @Published var webhookTestSuccess: Bool = false
    @Published var isTestingAlertScript: Bool = false
    @Published var alertScriptTestResult: String? = nil
    @Published var alertScriptTestSuccess: Bool = false
    @Published var isRunningSurfaceScan: Bool = false
    @Published var selectedSurfaceScanMode: DiskHealthMonitor.SurfaceScanMode = .quick
    @Published var surfaceScanProgress: DiskHealthMonitor.SurfaceScanProgress? = nil
    @Published var surfaceScanCancelToken: DiskHealthMonitor.SurfaceScanCancellationToken? = nil
    @Published var lastSurfaceScanSummary: String? = nil
    @Published var lastSurfaceScanOk: Bool = true
    @Published var isVerifyingVolumeInSettings: Bool = false
    @Published var diagnosticsStatusMsg: String? = nil
    @Published var keychainState: KeychainIntegrationState = SecretStore.shared.keychainState
    @Published var isOnboardingKeychain: Bool = false
    @Published var keychainStatusMessage: String? = nil
    @Published var keychainStatusIsError: Bool = false

    init() {
        self.botToken = ConfigManager.shared.resolvedTelegramBotToken
        self.webhookUrl = ConfigManager.shared.resolvedWebhookUrl
        self.keychainState = SecretStore.shared.keychainState
        refreshDiskList()
        checkLaunchAgent()
    }

    func checkLaunchAgent() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let bundleId = Bundle.main.bundleIdentifier ?? "io.github.disk-health-monitor"
        let plistPath = "\(home)/Library/LaunchAgents/\(bundleId).plist"
        launchAgentInstalled = FileManager.default.fileExists(atPath: plistPath)
    }

    func toggleLaunchAgent() {
        guard !isUpdatingLaunchAgent else { return }
        isUpdatingLaunchAgent = true
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let bundleId = Bundle.main.bundleIdentifier ?? "io.github.disk-health-monitor"
        let agentsDir = "\(home)/Library/LaunchAgents"
        let plistPath = "\(agentsDir)/\(bundleId).plist"
        let binaryPath = Bundle.main.executableURL?.resolvingSymlinksInPath().path
            ?? Bundle.main.executablePath
            ?? "/Applications/DiskHealthMonitor.app/Contents/MacOS/DiskHealthMonitor"
        let logsDir = ConfigManager.shared.logsDir
        let isCurrentlyInstalled = launchAgentInstalled

        DispatchQueue.global(qos: .userInitiated).async {
            // Temporarily ignore SIGTERM so `launchctl bootout` does not kill the currently
            // running GUI process if this instance was originally spawned by launchd.
            let prevSigTerm = signal(SIGTERM, SIG_IGN)
            defer {
                let prevPtr = unsafeBitCast(prevSigTerm, to: UnsafeRawPointer?.self)
                let ignPtr = unsafeBitCast(SIG_IGN, to: UnsafeRawPointer?.self)
                let errPtr = unsafeBitCast(SIG_ERR, to: UnsafeRawPointer?.self)
                if prevPtr != ignPtr && prevPtr != errPtr {
                    signal(SIGTERM, prevSigTerm)
                } else {
                    signal(SIGTERM, SIG_DFL)
                }
            }

            if isCurrentlyInstalled {
                let bootout = Process()
                bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                bootout.arguments = ["bootout", "gui/\(getuid())/\(bundleId)"]
                try? bootout.run()
                bootout.waitUntilExit()
                try? FileManager.default.removeItem(atPath: plistPath)
            } else {
                try? FileManager.default.createDirectory(atPath: agentsDir, withIntermediateDirectories: true)
                try? FileManager.default.createDirectory(atPath: logsDir, withIntermediateDirectories: true)
                let plistDict = SettingsViewModel.makeLaunchAgentPlistDict(bundleId: bundleId, binaryPath: binaryPath, logsDir: logsDir)
                if let plistData = try? PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0) {
                    try? plistData.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
                }
                // Ensure any stale registration is unloaded before bootstrapping
                let bootout = Process()
                bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                bootout.arguments = ["bootout", "gui/\(getuid())/\(bundleId)"]
                try? bootout.run()
                bootout.waitUntilExit()

                let bootstrap = Process()
                bootstrap.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                bootstrap.arguments = ["bootstrap", "gui/\(getuid())", plistPath]
                try? bootstrap.run()
                bootstrap.waitUntilExit()
            }
            DispatchQueue.main.async {
                self.checkLaunchAgent()
                self.isUpdatingLaunchAgent = false
            }
        }
    }

    func refreshDiskList() {
        DispatchQueue.global(qos: .userInitiated).async {
            var items: [(id: String, name: String)] = []
            let devices = IOKitTelemetryProvider.shared.listAllDevices(maxCount: 16)
            for d in devices {
                let prod = cStringToSwift(d.productName)
                let vendor = cStringToSwift(d.vendorName)
                let bsd = cStringToSwift(d.bsdName)
                let bus = cStringToSwift(d.interconnectType)
                let label = "\(vendor.isEmpty ? "" : vendor + " ")\(prod) (\(bsd), \(bus))"
                items.append((id: bsd, name: label))
            }

            let mounts = IOKitTelemetryProvider.shared.listLocalMountedVolumes()
            for m in mounts {
                items.append((id: m.path, name: "📂 \(m.displayName) (\(m.path))"))
            }

            let cfg = ConfigManager.shared.currentConfig
            if let customVol = cfg.targetVolumePath, !customVol.isEmpty,
               !items.contains(where: { $0.id == customVol }) {
                items.append((id: customVol, name: "📌 Configured Volume (\(customVol))"))
            }
            if let customDev = cfg.targetDeviceQuery, !customDev.isEmpty,
               !items.contains(where: { $0.id == customDev }) {
                items.append((id: customDev, name: "📌 Configured Device (\(customDev))"))
            }
            DispatchQueue.main.async {
                self.availableDisks = items
            }
        }
    }

    func isTargetSelected(_ id: String) -> Bool {
        let cfg = ConfigManager.shared.currentConfig
        if cfg.monitorAllDisks { return true }
        if cfg.monitoredTargets.contains(id) { return true }
        if cfg.targetVolumePath == id || cfg.targetDeviceQuery == id { return true }
        return false
    }

    func toggleDiskSelection(_ id: String) {
        ConfigManager.shared.toggleTargetInMonitoredList(id)
    }

    func toggleMonitorAllDisks() {
        ConfigManager.shared.updateConfig {
            $0.monitorAllDisks.toggle()
        }
    }

    private var tokenSaveWorkItem: DispatchWorkItem?

    func updateBotToken(_ newValue: String) {
        self.botToken = newValue
        tokenSaveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.commitBotTokenNow(newValue)
        }
        tokenSaveWorkItem = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func commitBotTokenNow(_ val: String) {
        tokenSaveWorkItem?.cancel()
        if val.isEmpty {
            _ = SecretStore.shared.deleteSecret(forKey: "telegramBotToken", allowInteractiveKeychain: false)
            ConfigManager.shared.updateConfig { $0.telegramBotToken = "" }
        } else {
            _ = SecretStore.shared.setSecret(val, forKey: "telegramBotToken", allowInteractiveKeychain: false)
            ConfigManager.shared.updateConfig { $0.telegramBotToken = "REDACTED_IN_KEYCHAIN" }
        }
    }

    private var webhookSaveWorkItem: DispatchWorkItem?

    func updateWebhookUrl(_ newValue: String) {
        self.webhookUrl = newValue
        webhookSaveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.commitWebhookUrlNow(newValue)
        }
        webhookSaveWorkItem = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func commitWebhookUrlNow(_ val: String) {
        webhookSaveWorkItem?.cancel()
        let trimmed = val.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            _ = SecretStore.shared.deleteSecret(forKey: "webhookUrl", allowInteractiveKeychain: false)
            ConfigManager.shared.updateConfig { $0.webhookUrl = "" }
        } else {
            _ = SecretStore.shared.setSecret(trimmed, forKey: "webhookUrl", allowInteractiveKeychain: false)
            ConfigManager.shared.updateConfig { $0.webhookUrl = "REDACTED_IN_KEYCHAIN" }
        }
    }

    func onboardCredentialsToKeychainAction() {
        guard !isOnboardingKeychain else { return }
        commitBotTokenNow(botToken)
        commitWebhookUrlNow(webhookUrl)
        isOnboardingKeychain = true
        keychainStatusMessage = nil

        let currentBotToken = self.botToken
        let currentWebhook = self.webhookUrl.trimmingCharacters(in: .whitespacesAndNewlines)

        DispatchQueue.global(qos: .userInitiated).async {
            let res = SecretStore.shared.onboardOrUnlockKeychainInteractive(secretsToStore: [
                "telegramBotToken": currentBotToken,
                "webhookUrl": currentWebhook
            ])
            DispatchQueue.main.async {
                self.isOnboardingKeychain = false
                self.keychainState = SecretStore.shared.keychainState
                switch res {
                case .success:
                    ConfigManager.shared.updateConfig { $0.useKeychainStorage = true }
                    self.botToken = ConfigManager.shared.resolvedTelegramBotToken
                    self.webhookUrl = ConfigManager.shared.resolvedWebhookUrl
                    self.keychainStatusIsError = false
                    self.keychainStatusMessage = "macOS Keychain unlocked and credentials synchronized."
                case .failure(let err):
                    ConfigManager.shared.updateConfig { $0.useKeychainStorage = false }
                    self.keychainStatusIsError = true
                    self.keychainStatusMessage = err.localizedDescription
                }
            }
        }
    }

    func switchToLocalStorageOnlyAction() {
        SecretStore.shared.switchToLocalRestrictedStorageOnly()
        ConfigManager.shared.updateConfig { $0.useKeychainStorage = false }
        self.keychainState = SecretStore.shared.keychainState
        self.keychainStatusIsError = false
        self.keychainStatusMessage = "Using local restricted storage (.env / .secrets.json 0600). macOS Keychain prompts disabled."
    }

    func runSurfaceScanAction() {
        guard !isRunningSurfaceScan else { return }
        let mode = selectedSurfaceScanMode
        let token = DiskHealthMonitor.SurfaceScanCancellationToken()
        surfaceScanCancelToken = token
        isRunningSurfaceScan = true
        lastSurfaceScanSummary = nil

        DispatchQueue.global(qos: .userInitiated).async {
            let res = DiskHealthMonitor.shared.runSurfaceReadScan(
                mode: mode,
                cancellationToken: token
            ) { prog in
                DispatchQueue.main.async {
                    self.surfaceScanProgress = prog
                }
            }
            DispatchQueue.main.async {
                self.isRunningSurfaceScan = false
                self.surfaceScanCancelToken = nil
                self.lastSurfaceScanOk = res.ok
                self.lastSurfaceScanSummary = res.summary
            }
        }
    }

    func cancelSurfaceScanAction() {
        surfaceScanCancelToken?.cancel()
        lastSurfaceScanSummary = "Cancelling surface scan..."
    }

    func runVolumeVerificationAction() {
        guard !isVerifyingVolumeInSettings && !DiskHealthMonitor.shared.isVerifyingVolume else { return }
        isVerifyingVolumeInSettings = true
        diagnosticsStatusMsg = "Running diskutil verifyVolume on active target..."
        DiskHealthMonitor.shared.runVolumeVerification(sendTelegram: false) { ok, summary in
            DispatchQueue.main.async {
                self.isVerifyingVolumeInSettings = false
                self.diagnosticsStatusMsg = "Volume Verification: \(summary)"
            }
        }
    }

    func runTelegramTest() {
        commitBotTokenNow(botToken)
        isTestingTelegram = true
        testResult = nil
        let token = botToken
        let chatId = ConfigManager.shared.resolvedTelegramChatId

        TelegramNotifier.shared.sendTestMessage(token: token, chatId: chatId) { success, message in
            DispatchQueue.main.async {
                self.isTestingTelegram = false
                self.testSuccess = success
                self.testResult = message
            }
        }
    }

    func runWebhookTest() {
        commitWebhookUrlNow(webhookUrl)
        isTestingWebhook = true
        webhookTestResult = nil
        let targetUrl = webhookUrl

        WebhookNotifier.shared.sendTestWebhook(webhookUrl: targetUrl) { success, message in
            DispatchQueue.main.async {
                self.isTestingWebhook = false
                self.webhookTestSuccess = success
                self.webhookTestResult = message
            }
        }
    }

    func browseAlertScriptAction() {
        let panel = NSOpenPanel()
        panel.title = "Select Executable Alert Script"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            ConfigManager.shared.updateConfig { $0.alertScriptPath = url.path }
        }
    }

    func runAlertScriptTest() {
        isTestingAlertScript = true
        alertScriptTestResult = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let res = DiskHealthMonitor.shared.testAlertScript()
            DispatchQueue.main.async {
                self.isTestingAlertScript = false
                self.alertScriptTestSuccess = res.ok
                self.alertScriptTestResult = res.summary
            }
        }
    }

    func exportConfigAction() {
        let panel = NSSavePanel()
        panel.title = "Export Sanitized Config"
        panel.nameFieldStringValue = "disk-health-config.json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            let json = ConfigManager.shared.exportSanitizedConfigJSON(includeSecrets: false)
            if let data = json.data(using: .utf8),
               AtomicFileWriter.writeRestricted(data: data, toPath: url.path, permissions: 0o600) {
                diagnosticsStatusMsg = "Saved configuration to \(url.lastPathComponent)"
            } else {
                diagnosticsStatusMsg = "Failed to save configuration."
            }
        }
    }

    func importConfigAction() {
        let panel = NSOpenPanel()
        panel.title = "Import Configuration JSON"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            if ConfigManager.shared.importConfigFile(at: url) {
                self.botToken = ConfigManager.shared.resolvedTelegramBotToken
                self.webhookUrl = ConfigManager.shared.resolvedWebhookUrl
                diagnosticsStatusMsg = "Imported configuration from \(url.lastPathComponent)"
            } else {
                diagnosticsStatusMsg = "Failed to decode configuration file."
            }
        }
    }

    func exportDiagnosticReportAction() {
        let panel = NSSavePanel()
        panel.title = "Export Full Diagnostic Report"
        panel.nameFieldStringValue = "diagnostic-report.json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            if let savedPath = DiagnosticExporter.shared.saveDiagnosticReportToFile(at: url.path) {
                diagnosticsStatusMsg = "Saved diagnostic report to \((savedPath as NSString).lastPathComponent)"
            } else {
                diagnosticsStatusMsg = "Failed to save diagnostic report."
            }
        }
    }

    func exportHtmlReportAction() {
        let panel = NSSavePanel()
        panel.title = "Export Standalone HTML Health Report"
        panel.nameFieldStringValue = "disk-health-report.html"
        panel.allowedContentTypes = [.html]
        if panel.runModal() == .OK, let url = panel.url {
            if let savedPath = DiagnosticExporter.shared.saveDiagnosticReportHTMLToFile(at: url.path) {
                diagnosticsStatusMsg = "Saved HTML report to \((savedPath as NSString).lastPathComponent)"
            } else {
                diagnosticsStatusMsg = "Failed to save HTML report."
            }
        }
    }

    static func makeLaunchAgentPlistDict(bundleId: String, binaryPath: String, logsDir: String) -> [String: Any] {
        return [
            "Label": bundleId,
            "ProgramArguments": [binaryPath, "--menubar"],
            "WorkingDirectory": logsDir,
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "StandardOutPath": "\(logsDir)/launchd.out.log",
            "StandardErrorPath": "\(logsDir)/launchd.err.log",
            "ProcessType": "Interactive"
        ]
    }
}

// MARK: - Settings Window Controller

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    convenience init() {
        let vm = SettingsWindowController.sharedVM
        let settingsView = SettingsView(viewModel: vm)
        let hostingController = NSHostingController(rootView: settingsView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Disk Health Monitor Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 700, height: 650))
        window.minSize = NSSize(width: 700, height: 650)
        window.center()
        window.isReleasedWhenClosed = false
        self.init(window: window)
    }

    private static let sharedVM = SettingsViewModel()

    func showSettings(tab: Int? = nil) {
        if let tab = tab {
            SettingsWindowController.sharedVM.selectedTab = tab
        }
        SettingsWindowController.sharedVM.refreshDiskList()
        SettingsWindowController.sharedVM.checkLaunchAgent()
        SettingsWindowController.sharedVM.botToken = ConfigManager.shared.resolvedTelegramBotToken
        SettingsWindowController.sharedVM.webhookUrl = ConfigManager.shared.resolvedWebhookUrl
        SettingsWindowController.sharedVM.keychainState = SecretStore.shared.keychainState
        guard let window = self.window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
