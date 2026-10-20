import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Darwin

// MARK: - Native macOS Settings Window (Cmd+,)

final class SettingsViewModel: ObservableObject {
    @Published var selectedTab: Int = 0
    @Published var availableDisks: [(id: String, name: String)] = []
    @Published var launchAgentInstalled: Bool = false
    @Published var isUpdatingLaunchAgent: Bool = false
    @Published var botToken: String = ""
    @Published var showToken: Bool = false
    @Published var isTestingTelegram: Bool = false
    @Published var testResult: String? = nil
    @Published var testSuccess: Bool = false
    @Published var diagnosticsStatusMsg: String? = nil

    init() {
        self.botToken = ConfigManager.shared.resolvedTelegramBotToken
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
            var devices = [DiskHardwareMetrics](repeating: DiskHardwareMetrics(), count: 16)
            let count = DiskListAllDevices(&devices, 16)
            for i in 0..<Int(count) {
                let d = devices[i]
                let prod = cStringToSwift(d.productName)
                let vendor = cStringToSwift(d.vendorName)
                let bsd = cStringToSwift(d.bsdName)
                let bus = cStringToSwift(d.interconnectType)
                let label = "\(vendor.isEmpty ? "" : vendor + " ")\(prod) (\(bsd), \(bus))"
                items.append((id: bsd, name: label))
            }

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
                            items.append((id: volPath, name: "📂 \(displayName) (\(volPath))"))
                        }
                    }
                }
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
            _ = SecretStore.shared.deleteSecret(forKey: "telegramBotToken")
            ConfigManager.shared.updateConfig { $0.telegramBotToken = "" }
        } else {
            _ = SecretStore.shared.setSecret(val, forKey: "telegramBotToken")
            ConfigManager.shared.updateConfig { $0.telegramBotToken = "REDACTED_IN_KEYCHAIN" }
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

    func exportConfigAction() {
        let panel = NSSavePanel()
        panel.title = "Export Sanitized Config"
        panel.nameFieldStringValue = "disk-health-config.json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            let json = ConfigManager.shared.exportSanitizedConfigJSON(includeSecrets: false)
            do {
                try json.write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                diagnosticsStatusMsg = "Saved configuration to \(url.lastPathComponent)"
            } catch {
                diagnosticsStatusMsg = "Failed to save configuration: \(error.localizedDescription)"
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

// MARK: - Reusable Settings UI Components

struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    let iconColor: Color
    let content: Content

    init(title: String, icon: String, iconColor: Color = .accentColor, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.iconColor = iconColor
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(iconColor)
                    .frame(width: 16)
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundColor(.secondary)
                    .tracking(0.5)
                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 9) {
                content
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }
}

struct SettingsRow<Control: View>: View {
    let title: String
    let subtitle: String?
    let control: Control

    init(title: String, subtitle: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.subtitle = subtitle
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                if let subtitle = subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
    }
}

struct SettingsSliderRow: View {
    let title: String
    let subtitle: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let formattedValue: String
    let badgeColor: Color

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 205, alignment: .leading)

            Slider(
                value: Binding(
                    get: { value },
                    set: { rawVal in
                        let stepped = (rawVal / step).rounded() * step
                        let clamped = min(range.upperBound, max(range.lowerBound, stepped))
                        if clamped != value {
                            value = clamped
                        }
                    }
                ),
                in: range
            )
            .frame(maxWidth: .infinity)

            Text(formattedValue)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(badgeColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(width: 64, alignment: .center)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(badgeColor.opacity(0.14))
                )
        }
    }
}

struct SettingsView: View {
    @ObservedObject var configMgr = ConfigManager.shared
    @ObservedObject var viewModel: SettingsViewModel

    private let tabs: [(tag: Int, title: String, icon: String)] = [
        (0, "General", "gearshape.fill"),
        (1, "Thresholds", "slider.horizontal.3"),
        (2, "Notifications", "bell.badge.fill"),
        (3, "Diagnostics", "wrench.and.screwdriver.fill")
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Custom Native-Style Toolbar Tab Switcher (avoids macOS NSTabView label squishing)
            HStack(spacing: 8) {
                ForEach(tabs, id: \.tag) { tab in
                    let isSelected = (viewModel.selectedTab == tab.tag)
                    Button(action: {
                        viewModel.selectedTab = tab.tag
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 12.5, weight: .semibold))
                            Text(tab.title)
                                .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                        }
                        .foregroundColor(isSelected ? .white : .primary)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.06))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            // Active Tab Content
            Group {
                switch viewModel.selectedTab {
                case 0:
                    GeneralSettingsTab(configMgr: configMgr, viewModel: viewModel)
                case 1:
                    ThresholdsSettingsTab(configMgr: configMgr)
                case 2:
                    NotificationsSettingsTab(configMgr: configMgr, viewModel: viewModel)
                default:
                    DiagnosticsAndExportTab(configMgr: configMgr, viewModel: viewModel)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 630, height: 590)
    }
}

struct GeneralSettingsTab: View {
    @ObservedObject var configMgr: ConfigManager
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                SettingsCard(title: "Monitored Storage Target", icon: "externaldrive.fill.badge.checkmark", iconColor: .blue) {
                    SettingsRow(
                        title: "Target Drive or Volume",
                        subtitle: "Choose a specific physical disk, mounted volume, or automatic external detection."
                    ) {
                        Picker("", selection: Binding(
                            get: {
                                if let v = configMgr.config.targetVolumePath, !v.isEmpty { return v }
                                if let d = configMgr.config.targetDeviceQuery, !d.isEmpty { return d }
                                return "auto"
                            },
                            set: { newVal in
                                if newVal == "auto" {
                                    DiskHealthMonitor.shared.setMonitoredTarget(volumePath: nil, deviceQuery: nil)
                                } else if newVal.hasPrefix("/") {
                                    DiskHealthMonitor.shared.setMonitoredTarget(volumePath: newVal, deviceQuery: nil)
                                } else {
                                    DiskHealthMonitor.shared.setMonitoredTarget(volumePath: nil, deviceQuery: newVal)
                                }
                            }
                        )) {
                            Text("Auto-detect First External Volume").tag("auto")
                            Divider()
                            ForEach(viewModel.availableDisks, id: \.id) { disk in
                                Text(disk.name).tag(disk.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 260)
                    }
                }

                SettingsCard(title: "Sampling & Active Health Probes", icon: "waveform.path.ecg", iconColor: .green) {
                    SettingsSliderRow(
                        title: "Background Poll Interval",
                        subtitle: "S.M.A.R.T. & I/O telemetry refresh rate",
                        value: Binding(
                            get: { configMgr.config.pollIntervalSeconds },
                            set: { val in configMgr.updateConfig { $0.pollIntervalSeconds = val } }
                        ),
                        range: 10...300,
                        step: 5,
                        formattedValue: "\(Int(configMgr.config.pollIntervalSeconds))s",
                        badgeColor: .blue
                    )

                    Divider()

                    SettingsRow(
                        title: "Active Filesystem Canary Probe",
                        subtitle: "Periodically writes and verifies a test marker (.disk_health_canary) to measure I/O latency and detect APFS freezes."
                    ) {
                        Toggle("", isOn: Binding(
                            get: { configMgr.config.enableActiveCanary },
                            set: { val in configMgr.updateConfig { $0.enableActiveCanary = val } }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                }

                SettingsCard(title: "System Startup & Background Service", icon: "power.circle.fill", iconColor: .purple) {
                    SettingsRow(
                        title: "macOS LaunchAgent Service",
                        subtitle: viewModel.launchAgentInstalled
                            ? "Active — Disk Health Monitor starts automatically when you log in."
                            : "Not installed — application only runs when launched manually."
                    ) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(viewModel.launchAgentInstalled ? Color.green : Color.secondary.opacity(0.4))
                                .frame(width: 8, height: 8)
                            Button(viewModel.launchAgentInstalled ? "Uninstall Service" : "Register Service") {
                                viewModel.toggleLaunchAgent()
                            }
                            .controlSize(.regular)
                            .disabled(viewModel.isUpdatingLaunchAgent)
                        }
                    }
                }
            }
            .padding(8)
        }
        .onAppear {
            viewModel.refreshDiskList()
            viewModel.checkLaunchAgent()
        }
    }
}

struct ThresholdsSettingsTab: View {
    @ObservedObject var configMgr: ConfigManager

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                SettingsCard(title: "Thermal Thresholds (S.M.A.R.T.)", icon: "thermometer.medium", iconColor: .orange) {
                    SettingsSliderRow(
                        title: "Temperature Warning",
                        subtitle: "Triggers yellow elevated thermal alert",
                        value: Binding(
                            get: { Double(configMgr.config.tempWarningCelsius) },
                            set: { val in
                                let v = Int(val)
                                configMgr.updateConfig {
                                    $0.tempWarningCelsius = v
                                    if v >= $0.tempCriticalCelsius {
                                        $0.tempCriticalCelsius = min(95, v + 1)
                                    }
                                }
                            }
                        ),
                        range: 40...80,
                        step: 1,
                        formattedValue: "\(configMgr.config.tempWarningCelsius)°C",
                        badgeColor: .orange
                    )

                    Divider()

                    SettingsSliderRow(
                        title: "Temperature Critical",
                        subtitle: "Triggers critical overheating alert",
                        value: Binding(
                            get: { Double(configMgr.config.tempCriticalCelsius) },
                            set: { val in
                                let v = Int(val)
                                configMgr.updateConfig {
                                    $0.tempCriticalCelsius = v
                                    if v <= $0.tempWarningCelsius {
                                        $0.tempWarningCelsius = max(40, v - 1)
                                    }
                                }
                            }
                        ),
                        range: 50...95,
                        step: 1,
                        formattedValue: "\(configMgr.config.tempCriticalCelsius)°C",
                        badgeColor: .red
                    )
                }

                SettingsCard(title: "Volume Capacity & Free Space", icon: "internaldrive.fill", iconColor: .blue) {
                    SettingsSliderRow(
                        title: "Disk Used Warning",
                        subtitle: "Warn when volume usage reaches %",
                        value: Binding(
                            get: { configMgr.config.diskUsedWarningPercent },
                            set: { val in
                                configMgr.updateConfig {
                                    $0.diskUsedWarningPercent = val
                                    if val >= $0.diskUsedCriticalPercent {
                                        $0.diskUsedCriticalPercent = min(99.0, val + 1.0)
                                    }
                                }
                            }
                        ),
                        range: 50...98,
                        step: 1,
                        formattedValue: String(format: "%.0f%%", configMgr.config.diskUsedWarningPercent),
                        badgeColor: .orange
                    )

                    Divider()

                    SettingsSliderRow(
                        title: "Disk Used Critical",
                        subtitle: "Critical alert when usage reaches %",
                        value: Binding(
                            get: { configMgr.config.diskUsedCriticalPercent },
                            set: { val in
                                configMgr.updateConfig {
                                    $0.diskUsedCriticalPercent = val
                                    if val <= $0.diskUsedWarningPercent {
                                        $0.diskUsedWarningPercent = max(50.0, val - 1.0)
                                    }
                                }
                            }
                        ),
                        range: 60...99,
                        step: 1,
                        formattedValue: String(format: "%.0f%%", configMgr.config.diskUsedCriticalPercent),
                        badgeColor: .red
                    )

                    Divider()

                    HStack(spacing: 16) {
                        SettingsRow(
                            title: "Min Free Warning",
                            subtitle: "Low space warning floor"
                        ) {
                            HStack(spacing: 6) {
                                Text("\(Int(configMgr.config.minFreeSpaceWarningGB)) GB")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .frame(width: 62, alignment: .center)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.14)))

                                Stepper("", value: Binding(
                                    get: { Int(configMgr.config.minFreeSpaceWarningGB) },
                                    set: { val in
                                        configMgr.updateConfig {
                                            $0.minFreeSpaceWarningGB = Double(val)
                                            if Double(val) <= $0.minFreeSpaceCriticalGB {
                                                $0.minFreeSpaceCriticalGB = max(1.0, Double(val) - 5.0)
                                            }
                                        }
                                    }
                                ), in: 5...250, step: 5)
                                .labelsHidden()
                            }
                        }

                        Divider()
                            .frame(height: 28)

                        SettingsRow(
                            title: "Min Free Critical",
                            subtitle: "Critical space floor"
                        ) {
                            HStack(spacing: 6) {
                                Text("\(Int(configMgr.config.minFreeSpaceCriticalGB)) GB")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(.red)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .frame(width: 62, alignment: .center)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.14)))

                                Stepper("", value: Binding(
                                    get: { Int(configMgr.config.minFreeSpaceCriticalGB) },
                                    set: { val in
                                        configMgr.updateConfig {
                                            $0.minFreeSpaceCriticalGB = Double(val)
                                            if Double(val) >= $0.minFreeSpaceWarningGB {
                                                $0.minFreeSpaceWarningGB = min(250.0, Double(val) + 5.0)
                                            }
                                        }
                                    }
                                ), in: 1...100, step: 1)
                                .labelsHidden()
                            }
                        }
                    }
                }

                SettingsCard(title: "Hardware Bus & Factory Defaults", icon: "cable.connector.horizontal", iconColor: .teal) {
                    SettingsRow(
                        title: "Minimum Expected USB / Bus Speed",
                        subtitle: "Warn if a cable or hub negotiates below this link rate"
                    ) {
                        Picker("", selection: Binding(
                            get: { configMgr.config.minExpectedUsbSpeedBps },
                            set: { val in configMgr.updateConfig { $0.minExpectedUsbSpeedBps = val } }
                        )) {
                            Text("Disabled (No Speed Check)").tag(UInt64(0))
                            Text("480 Mbps (USB 2.0)").tag(UInt64(480_000_000))
                            Text("5 Gbps (USB 3.0 SuperSpeed)").tag(UInt64(5_000_000_000))
                            Text("10 Gbps (USB 3.2 SuperSpeed+)").tag(UInt64(10_000_000_000))
                            Text("20 Gbps (USB 3.2 2x2 / USB4)").tag(UInt64(20_000_000_000))
                            Text("40 Gbps (Thunderbolt 3/4)").tag(UInt64(40_000_000_000))
                        }
                        .labelsHidden()
                        .frame(width: 235)
                    }

                    Divider()

                    SettingsRow(
                        title: "Factory Default Thresholds",
                        subtitle: "Restore 58°C/68°C thermal limits, 85%/93% capacity limits, and 5 Gbps bus speed"
                    ) {
                        Button("Reset to Defaults") {
                            configMgr.updateConfig {
                                $0.tempWarningCelsius = 58
                                $0.tempCriticalCelsius = 68
                                $0.diskUsedWarningPercent = 85.0
                                $0.diskUsedCriticalPercent = 93.0
                                $0.minFreeSpaceWarningGB = 30.0
                                $0.minFreeSpaceCriticalGB = 15.0
                                $0.minExpectedUsbSpeedBps = 5_000_000_000
                            }
                        }
                    }
                }
            }
            .padding(8)
        }
    }
}

struct NotificationsSettingsTab: View {
    @ObservedObject var configMgr: ConfigManager
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsCard(title: "macOS Notification Center", icon: "bell.badge.fill", iconColor: .red) {
                    SettingsRow(
                        title: "Enable Desktop Alert Banners",
                        subtitle: "Deliver native macOS alerts when drive health transitions to Warning, Critical, or Recovered."
                    ) {
                        Toggle("", isOn: Binding(
                            get: { configMgr.config.enableNativeNotifications },
                            set: { val in configMgr.updateConfig { $0.enableNativeNotifications = val } }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                }

                SettingsCard(title: "Telegram Bot Integration", icon: "paperplane.fill", iconColor: .blue) {
                    HStack(alignment: .center, spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Telegram Bot Token")
                                .font(.system(size: 13, weight: .medium))
                            Text("Encrypted in macOS Keychain")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .frame(width: 175, alignment: .leading)

                        HStack(spacing: 6) {
                            if viewModel.showToken {
                                TextField("123456789:ABCDEF...", text: Binding(
                                    get: { viewModel.botToken },
                                    set: { val in viewModel.updateBotToken(val) }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                            } else {
                                SecureField("Enter Bot Token from @BotFather", text: Binding(
                                    get: { viewModel.botToken },
                                    set: { val in viewModel.updateBotToken(val) }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                            }

                            Button(action: { viewModel.showToken.toggle() }) {
                                Image(systemName: viewModel.showToken ? "eye.slash.fill" : "eye.fill")
                                    .foregroundColor(.secondary)
                                    .frame(width: 22, height: 22)
                            }
                            .buttonStyle(.borderless)
                            .help(viewModel.showToken ? "Hide Bot Token" : "Reveal Bot Token")
                        }
                    }

                    Divider()

                    HStack(alignment: .center, spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Telegram Chat ID")
                                .font(.system(size: 13, weight: .medium))
                            Text("Target user or channel ID")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .frame(width: 175, alignment: .leading)

                        TextField("e.g. 123456789 or -100...", text: Binding(
                            get: { configMgr.config.telegramChatId.isEmpty ? configMgr.resolvedTelegramChatId : configMgr.config.telegramChatId },
                            set: { val in configMgr.updateConfig { $0.telegramChatId = val } }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    }

                    Divider()

                    SettingsRow(
                        title: "Daily Morning Health Digest (09:00)",
                        subtitle: "Automatically send a silent daily status summary every morning at 09:00 local time."
                    ) {
                        Toggle("", isOn: Binding(
                            get: { DiskHealthMonitor.shared.dailySummaryEnabled },
                            set: { val in DiskHealthMonitor.shared.dailySummaryEnabled = val }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }

                    Divider()

                    SettingsRow(
                        title: "Verify Telegram Delivery",
                        subtitle: "Send an immediate test notification to confirm your Bot Token and Chat ID."
                    ) {
                        Button(action: { viewModel.runTelegramTest() }) {
                            HStack(spacing: 6) {
                                if viewModel.isTestingTelegram {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "paperplane.fill")
                                }
                                Text("Send Test Message")
                            }
                            .padding(.horizontal, 4)
                        }
                        .disabled(viewModel.isTestingTelegram || viewModel.botToken.isEmpty || configMgr.resolvedTelegramChatId.isEmpty)
                    }

                    if let result = viewModel.testResult {
                        HStack(alignment: .center, spacing: 8) {
                            Image(systemName: viewModel.testSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(viewModel.testSuccess ? .green : .red)
                            Text(result)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundColor(viewModel.testSuccess ? .primary : .red)
                            Spacer()
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill((viewModel.testSuccess ? Color.green : Color.red).opacity(0.12))
                        )
                    }
                }
            }
            .padding(8)
        }
        .onAppear {
            viewModel.botToken = configMgr.resolvedTelegramBotToken
        }
        .onDisappear {
            viewModel.commitBotTokenNow(viewModel.botToken)
        }
    }
}

struct DiagnosticsAndExportTab: View {
    @ObservedObject var configMgr: ConfigManager
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsCard(title: "Active Storage & Log Locations", icon: "folder.fill", iconColor: .blue) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Configuration File")
                                .font(.system(size: 13, weight: .medium))
                            Text(configMgr.configFilePath)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button(action: {
                            NSWorkspace.shared.selectFile(configMgr.configFilePath, inFileViewerRootedAtPath: configMgr.configDir)
                        }) {
                            Text("Reveal in Finder")
                                .frame(width: 128)
                        }
                    }

                    Divider()

                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Runtime Logs Directory")
                                .font(.system(size: 13, weight: .medium))
                            Text(configMgr.logsDir)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button(action: {
                            NSWorkspace.shared.open(URL(fileURLWithPath: configMgr.logsDir))
                        }) {
                            Text("Open Logs Folder")
                                .frame(width: 128)
                        }
                    }
                }

                SettingsCard(title: "Configuration & Telemetry Exports", icon: "square.and.arrow.up.fill", iconColor: .green) {
                    SettingsRow(
                        title: "Export Sanitized Configuration",
                        subtitle: "Save a shareable copy of config.json with sensitive tokens masked."
                    ) {
                        Button(action: {
                            viewModel.exportConfigAction()
                        }) {
                            Text("Export Config...")
                                .frame(width: 128)
                        }
                    }

                    Divider()

                    SettingsRow(
                        title: "Import Configuration Profile",
                        subtitle: "Restore configuration settings from an exported JSON profile."
                    ) {
                        Button(action: {
                            viewModel.importConfigAction()
                        }) {
                            Text("Import Config...")
                                .frame(width: 128)
                        }
                    }

                    Divider()

                    SettingsRow(
                        title: "Export Full Diagnostic Report (JSON / HTML)",
                        subtitle: "Generate a JSON diagnostic bundle or standalone HTML RMA report."
                    ) {
                        HStack(spacing: 8) {
                            Button(action: {
                                viewModel.exportDiagnosticReportAction()
                            }) {
                                Text("Export JSON...")
                            }
                            Button(action: {
                                viewModel.exportHtmlReportAction()
                            }) {
                                Text("Export HTML...")
                            }
                        }
                    }

                    Divider()

                    SettingsRow(
                        title: "Inspect Historical Event Log",
                        subtitle: "Open logs/health.log in your default log or text viewer."
                    ) {
                        Button(action: {
                            NSWorkspace.shared.open(URL(fileURLWithPath: configMgr.logFilePath))
                        }) {
                            Text("View Health Log")
                                .frame(width: 128)
                        }
                    }
                }

                SettingsCard(title: "State & Baseline Maintenance", icon: "arrow.counterclockwise.circle.fill", iconColor: .orange) {
                    SettingsRow(
                        title: "Reset Persistent Baselines",
                        subtitle: "Clear recorded peak temperatures, baseline error counters, and alert cooldown timers."
                    ) {
                        Button(action: {
                            DiskHealthMonitor.shared.resetBaselines()
                            _ = DiskHealthMonitor.shared.evaluateHealth(forceCanary: false, allowNotifications: false)
                            viewModel.diagnosticsStatusMsg = "Baselines and persistent state reset to clean defaults."
                        }) {
                            Text("Reset Baselines")
                                .frame(width: 128)
                        }
                    }

                    if let msg = viewModel.diagnosticsStatusMsg {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text(msg)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundColor(.primary)
                            Spacer()
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.green.opacity(0.12)))
                    }
                }
            }
            .padding(8)
        }
    }
}

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    convenience init() {
        let vm = SettingsWindowController.sharedVM
        let settingsView = SettingsView(viewModel: vm)
        let hostingController = NSHostingController(rootView: settingsView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Disk Health Monitor Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 630, height: 590))
        window.center()
        window.isReleasedWhenClosed = false
        self.init(window: window)
    }

    private static let sharedVM = SettingsViewModel()

    func showSettings() {
        SettingsWindowController.sharedVM.refreshDiskList()
        SettingsWindowController.sharedVM.checkLaunchAgent()
        SettingsWindowController.sharedVM.botToken = ConfigManager.shared.resolvedTelegramBotToken
        guard let window = self.window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
