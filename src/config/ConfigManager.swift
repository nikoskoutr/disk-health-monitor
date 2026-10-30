// ============================================================================
// File: ConfigManager.swift
// Module: Layer 2 (Infrastructure & Configuration)
// Purpose: Manages 5-tier configuration precedence (CLI > Env > .env > config.json > Defaults),
//          atomic 0600 persistence, credential masking, and 5MB rotating event logging.
// Concurrency: Thread-safe via NSRecursiveLock (configLock) and NSLock (logLock).
//              ObservableObject publishing synchronized to @MainActor.
// ============================================================================

import Foundation
import Combine
import Darwin

// MARK: - Configuration Model

/// Strongly-typed configuration schema representing all tunable monitoring parameters.
struct DiskHealthConfig: Codable, Equatable {
    var targetVolumePath: String? = nil
    var targetDeviceQuery: String? = nil
    var monitorAllDisks: Bool = false
    var monitoredTargets: [String] = []
    var requiredSubpaths: [String] = []
    var enableActiveCanary: Bool = true
    var pollIntervalSeconds: TimeInterval = 30.0
    var alertCooldownSeconds: TimeInterval = 3600.0
    var tempWarningCelsius: Int = 58
    var tempCriticalCelsius: Int = 68
    var diskUsedWarningPercent: Double = 85.0
    var diskUsedCriticalPercent: Double = 93.0
    var minFreeSpaceCriticalGB: Double = 15.0
    var minFreeSpaceWarningGB: Double = 30.0
    var minExpectedUsbSpeedBps: UInt64 = 5_000_000_000
    var enableNativeNotifications: Bool = true
    var enableCriticalSoundAlert: Bool = false
    var scheduledVerifyIntervalHours: Int = 0
    var telegramBotToken: String = ""
    var telegramChatId: String = ""
    var webhookUrl: String = ""
    var alertScriptPath: String = ""
    var useKeychainStorage: Bool = false
    var enableActionRulesEngine: Bool = true
    var actionRules: [ActionRule] = ActionRule.defaultStarterRules
    var metricsServerEnabled: Bool = false
    var metricsServerPort: Int = 9108
    var preSleepShieldEnabled: Bool = false

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = DiskHealthConfig()
        targetVolumePath = try container.decodeIfPresent(String.self, forKey: .targetVolumePath) ?? defaults.targetVolumePath
        targetDeviceQuery = try container.decodeIfPresent(String.self, forKey: .targetDeviceQuery) ?? defaults.targetDeviceQuery
        monitorAllDisks = try container.decodeIfPresent(Bool.self, forKey: .monitorAllDisks) ?? defaults.monitorAllDisks
        monitoredTargets = try container.decodeIfPresent([String].self, forKey: .monitoredTargets) ?? defaults.monitoredTargets
        requiredSubpaths = try container.decodeIfPresent([String].self, forKey: .requiredSubpaths) ?? defaults.requiredSubpaths
        enableActiveCanary = try container.decodeIfPresent(Bool.self, forKey: .enableActiveCanary) ?? defaults.enableActiveCanary
        pollIntervalSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .pollIntervalSeconds) ?? defaults.pollIntervalSeconds
        alertCooldownSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .alertCooldownSeconds) ?? defaults.alertCooldownSeconds
        tempWarningCelsius = try container.decodeIfPresent(Int.self, forKey: .tempWarningCelsius) ?? defaults.tempWarningCelsius
        tempCriticalCelsius = try container.decodeIfPresent(Int.self, forKey: .tempCriticalCelsius) ?? defaults.tempCriticalCelsius
        diskUsedWarningPercent = try container.decodeIfPresent(Double.self, forKey: .diskUsedWarningPercent) ?? defaults.diskUsedWarningPercent
        diskUsedCriticalPercent = try container.decodeIfPresent(Double.self, forKey: .diskUsedCriticalPercent) ?? defaults.diskUsedCriticalPercent
        minFreeSpaceCriticalGB = try container.decodeIfPresent(Double.self, forKey: .minFreeSpaceCriticalGB) ?? defaults.minFreeSpaceCriticalGB
        minFreeSpaceWarningGB = try container.decodeIfPresent(Double.self, forKey: .minFreeSpaceWarningGB) ?? defaults.minFreeSpaceWarningGB
        minExpectedUsbSpeedBps = try container.decodeIfPresent(UInt64.self, forKey: .minExpectedUsbSpeedBps) ?? defaults.minExpectedUsbSpeedBps
        enableNativeNotifications = try container.decodeIfPresent(Bool.self, forKey: .enableNativeNotifications) ?? defaults.enableNativeNotifications
        enableCriticalSoundAlert = try container.decodeIfPresent(Bool.self, forKey: .enableCriticalSoundAlert) ?? defaults.enableCriticalSoundAlert
        scheduledVerifyIntervalHours = try container.decodeIfPresent(Int.self, forKey: .scheduledVerifyIntervalHours) ?? defaults.scheduledVerifyIntervalHours
        telegramBotToken = try container.decodeIfPresent(String.self, forKey: .telegramBotToken) ?? defaults.telegramBotToken
        telegramChatId = try container.decodeIfPresent(String.self, forKey: .telegramChatId) ?? defaults.telegramChatId
        webhookUrl = try container.decodeIfPresent(String.self, forKey: .webhookUrl) ?? defaults.webhookUrl
        alertScriptPath = try container.decodeIfPresent(String.self, forKey: .alertScriptPath) ?? defaults.alertScriptPath
        useKeychainStorage = try container.decodeIfPresent(Bool.self, forKey: .useKeychainStorage) ?? defaults.useKeychainStorage
        enableActionRulesEngine = try container.decodeIfPresent(Bool.self, forKey: .enableActionRulesEngine) ?? defaults.enableActionRulesEngine
        actionRules = try container.decodeIfPresent([ActionRule].self, forKey: .actionRules) ?? defaults.actionRules
        metricsServerEnabled = try container.decodeIfPresent(Bool.self, forKey: .metricsServerEnabled) ?? defaults.metricsServerEnabled
        metricsServerPort = try container.decodeIfPresent(Int.self, forKey: .metricsServerPort) ?? defaults.metricsServerPort
        preSleepShieldEnabled = try container.decodeIfPresent(Bool.self, forKey: .preSleepShieldEnabled) ?? defaults.preSleepShieldEnabled
    }

    func validated() -> DiskHealthConfig {
        var v = self
        if v.pollIntervalSeconds < 5.0 { v.pollIntervalSeconds = 5.0 }
        if v.alertCooldownSeconds < 0.0 { v.alertCooldownSeconds = 0.0 }
        v.tempWarningCelsius = max(20, min(v.tempWarningCelsius, 110))
        v.tempCriticalCelsius = max(v.tempWarningCelsius + 1, min(v.tempCriticalCelsius, 120))
        v.diskUsedWarningPercent = max(10.0, min(v.diskUsedWarningPercent, 98.0))
        v.diskUsedCriticalPercent = max(v.diskUsedWarningPercent + 1.0, min(v.diskUsedCriticalPercent, 99.9))
        v.minFreeSpaceWarningGB = max(1.0, v.minFreeSpaceWarningGB)
        v.minFreeSpaceCriticalGB = max(0.5, min(v.minFreeSpaceCriticalGB, v.minFreeSpaceWarningGB - 0.5))
        v.metricsServerPort = max(1024, min(v.metricsServerPort, 65535))
        for i in v.actionRules.indices {
            v.actionRules[i].requiredConsecutivePolls = max(1, min(v.actionRules[i].requiredConsecutivePolls, 20))
            v.actionRules[i].cooldownSeconds = max(60.0, min(v.actionRules[i].cooldownSeconds, 604_800.0))
        }
        return v
    }
}

final class ConfigManager: ObservableObject, @unchecked Sendable {
    static let shared = ConfigManager()

    let configDir: String
    let stateDir: String
    let logsDir: String

    var stateFilePath: String { "\(stateDir)/state.json" }
    var historyFilePath: String { "\(stateDir)/history.json" }
    var configFilePath: String { "\(configDir)/config.json" }
    var logFilePath: String { "\(logsDir)/health.log" }
    var latestJsonPath: String { "\(stateDir)/latest_status.json" }

    private let configLock = NSRecursiveLock()
    private var persistedConfig: DiskHealthConfig
    private var _config: DiskHealthConfig
    private(set) var dotEnvTelegramToken: String? = nil
    private(set) var dotEnvChatId: String? = nil
    private(set) var dotEnvWebhookUrl: String? = nil

    static func isSecureUserOwnedFile(atPath path: String) -> Bool {
        var st = stat()
        if lstat(path, &st) != 0 {
            return false
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            return false
        }
        let uid = getuid()
        guard st.st_uid == uid || st.st_uid == 0 else {
            return false
        }
        guard (st.st_mode & 0o022) == 0 else {
            return false
        }
        return true
    }

    var config: DiskHealthConfig {
        get {
            configLock.lock()
            defer { configLock.unlock() }
            return _config
        }
        set {
            configLock.lock()
            _config = newValue
            configLock.unlock()
            notifyObjectWillChangeOnMain()
        }
    }

    private func notifyObjectWillChangeOnMain() {
        if Thread.isMainThread {
            self.objectWillChange.send()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.objectWillChange.send()
            }
        }
    }

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // 1. Resolve User Configuration Directory
        if let envConfigDir = ProcessInfo.processInfo.environment["DISK_HEALTH_CONFIG_DIR"], !envConfigDir.isEmpty {
            self.configDir = (envConfigDir as NSString).standardizingPath
        } else {
            let userConfig = "\(home)/.config/disk-health-monitor"
            let appSupport = "\(home)/Library/Application Support/DiskHealthMonitor"

            if FileManager.default.fileExists(atPath: userConfig) ||
               (try? FileManager.default.createDirectory(atPath: userConfig, withIntermediateDirectories: true)) != nil {
                self.configDir = userConfig
            } else if FileManager.default.fileExists(atPath: appSupport) ||
                      (try? FileManager.default.createDirectory(atPath: appSupport, withIntermediateDirectories: true)) != nil {
                self.configDir = appSupport
            } else {
                self.configDir = userConfig
            }
        }
        try? FileManager.default.createDirectory(atPath: self.configDir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.configDir)
        SecretStore.shared.configDir = self.configDir

        // 2. Resolve State and Logs Directory
        if let envLogsDir = ProcessInfo.processInfo.environment["DISK_HEALTH_LOGS_DIR"], !envLogsDir.isEmpty {
            self.logsDir = (envLogsDir as NSString).standardizingPath
            self.stateDir = self.logsDir
        } else {
            self.stateDir = self.configDir
            self.logsDir = "\(self.configDir)/logs"
        }
        try? FileManager.default.createDirectory(atPath: self.logsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: self.stateDir, withIntermediateDirectories: true)

        // 3. Load JSON configuration
        var loadedConfig = DiskHealthConfig()
        let configPath = "\(self.configDir)/config.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
           let decoded = try? JSONDecoder().decode(DiskHealthConfig.self, from: data) {
            loadedConfig = decoded.validated()
        }
        SecretStore.shared.useKeychainOptIn = loadedConfig.useKeychainStorage

        // 4. Migrate plaintext Telegram Bot Token & Webhook URL into SecretStore
        var needsResave = false
        if ConfigManager.isRealSecretToken(loadedConfig.telegramBotToken) {
            _ = SecretStore.shared.setSecret(loadedConfig.telegramBotToken, forKey: "telegramBotToken", allowInteractiveKeychain: false)
            loadedConfig.telegramBotToken = "REDACTED_IN_KEYCHAIN"
            needsResave = true
        }
        if ConfigManager.isRealSecretToken(loadedConfig.webhookUrl) {
            _ = SecretStore.shared.setSecret(loadedConfig.webhookUrl, forKey: "webhookUrl", allowInteractiveKeychain: false)
            loadedConfig.webhookUrl = "REDACTED_IN_KEYCHAIN"
            needsResave = true
        }
        if needsResave {
            ConfigManager.saveSanitizedConfigFile(loadedConfig, path: configPath)
        }
        self.persistedConfig = loadedConfig

        // 5. Apply .env configuration (runtime overrides without mutating persisted secrets)
        let (dotConfig, dotToken, dotChat, dotWebhook) = ConfigManager.loadDotEnvWithWebhook(into: loadedConfig, configDir: self.configDir)
        self.dotEnvTelegramToken = dotToken
        self.dotEnvChatId = dotChat
        if let dotWebhook = dotWebhook, ConfigManager.isRealSecretToken(dotWebhook) {
            self.dotEnvWebhookUrl = dotWebhook
        }

        // 6. Apply Environment variables
        self._config = ConfigManager.applyEnvironmentVariables(into: dotConfig).validated()

        // Enforce 0600 on config.json if it exists
        if FileManager.default.fileExists(atPath: configPath) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath)
        }
    }

    var currentConfig: DiskHealthConfig {
        configLock.lock()
        defer { configLock.unlock() }
        return _config
    }

    private static func isRealSecretToken(_ token: String) -> Bool {
        return !token.isEmpty &&
               token != "REDACTED_IN_KEYCHAIN" &&
               token != "Stored in Keychain" &&
               !token.contains("Protected")
    }

    var resolvedTelegramBotToken: String {
        configLock.lock()
        defer { configLock.unlock() }
        if let envToken = ProcessInfo.processInfo.environment["TELEGRAM_BOT_TOKEN"], !envToken.isEmpty {
            return envToken
        }
        if let dotToken = dotEnvTelegramToken, !dotToken.isEmpty {
            return dotToken
        }
        if let secret = SecretStore.shared.getSecret(forKey: "telegramBotToken", allowInteractiveKeychain: false), !secret.isEmpty {
            return secret
        }
        if ConfigManager.isRealSecretToken(_config.telegramBotToken) {
            return _config.telegramBotToken
        }
        return ""
    }

    var resolvedTelegramChatId: String {
        configLock.lock()
        defer { configLock.unlock() }
        if let envChat = ProcessInfo.processInfo.environment["TELEGRAM_CHAT_ID"], !envChat.isEmpty {
            return envChat
        }
        if let dotChat = dotEnvChatId, !dotChat.isEmpty {
            return dotChat
        }
        if !_config.telegramChatId.isEmpty {
            return _config.telegramChatId
        }
        return ""
    }

    var resolvedWebhookUrl: String {
        configLock.lock()
        defer { configLock.unlock() }
        if let envUrl = ProcessInfo.processInfo.environment["WEBHOOK_URL"], !envUrl.isEmpty {
            return envUrl
        }
        if let dotUrl = dotEnvWebhookUrl, !dotUrl.isEmpty {
            return dotUrl
        }
        if let secret = SecretStore.shared.getSecret(forKey: "webhookUrl", allowInteractiveKeychain: false), !secret.isEmpty {
            return secret
        }
        if ConfigManager.isRealSecretToken(_config.webhookUrl) {
            return _config.webhookUrl
        }
        return ""
    }

    var resolvedAlertScriptPath: String {
        configLock.lock()
        defer { configLock.unlock() }
        if let envScript = ProcessInfo.processInfo.environment["ALERT_SCRIPT_PATH"], !envScript.isEmpty {
            return envScript
        }
        if !_config.alertScriptPath.isEmpty {
            return _config.alertScriptPath
        }
        return ""
    }

    static func loadDotEnv(into cfg: DiskHealthConfig, configDir: String) -> (DiskHealthConfig, String?, String?) {
        let (res, tok, chat, _) = loadDotEnvWithWebhook(into: cfg, configDir: configDir)
        return (res, tok, chat)
    }

    static func loadDotEnvWithWebhook(into cfg: DiskHealthConfig, configDir: String) -> (DiskHealthConfig, String?, String?, String?) {
        var result = cfg
        var foundToken: String? = nil
        var foundChatId: String? = nil
        var foundWebhook: String? = nil
        let currentDir = FileManager.default.currentDirectoryPath

        var searchPaths: [String] = []
        if let customEnv = ProcessInfo.processInfo.environment["DISK_HEALTH_ENV_FILE"], !customEnv.isEmpty {
            searchPaths.append((customEnv as NSString).standardizingPath)
        }
        searchPaths.append("\(configDir)/.env")
        if ProcessInfo.processInfo.environment["DISK_HEALTH_DEV_DOTENV"] == "1" {
            searchPaths.append("\(currentDir)/.env")
        }

        for path in searchPaths {
            guard FileManager.default.fileExists(atPath: path),
                  ConfigManager.isSecureUserOwnedFile(atPath: path),
                  let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }

            for rawLine in content.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    let key = parts[0].trimmingCharacters(in: .whitespaces)
                    let val = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    if val.isEmpty { continue }

                    switch key {
                    case "DISK_HEALTH_VOLUME":
                        result.targetVolumePath = val
                    case "DISK_HEALTH_DEVICE":
                        result.targetDeviceQuery = val
                    case "MONITOR_ALL_DISKS":
                        result.monitorAllDisks = (val.lowercased() == "true" || val == "1" || val.lowercased() == "yes")
                    case "DISK_HEALTH_TARGETS":
                        result.monitoredTargets = val.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    case "DISK_HEALTH_REQUIRED_SUBPATHS":
                        result.requiredSubpaths = val.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    case "ENABLE_ACTIVE_CANARY":
                        result.enableActiveCanary = (val.lowercased() == "true" || val == "1" || val.lowercased() == "yes")
                    case "ENABLE_NATIVE_NOTIFICATIONS":
                        result.enableNativeNotifications = (val.lowercased() == "true" || val == "1" || val.lowercased() == "yes")
                    case "ENABLE_CRITICAL_SOUND_ALERT":
                        result.enableCriticalSoundAlert = (val.lowercased() == "true" || val == "1" || val.lowercased() == "yes")
                    case "SCHEDULED_VERIFY_INTERVAL_HOURS":
                        if let v = Int(val), v >= 0 { result.scheduledVerifyIntervalHours = v }
                    case "POLL_INTERVAL_SECONDS":
                        if let v = TimeInterval(val), v >= 5.0 { result.pollIntervalSeconds = v }
                    case "ALERT_COOLDOWN_SECONDS":
                        if let v = TimeInterval(val), v >= 0.0 { result.alertCooldownSeconds = v }
                    case "MIN_EXPECTED_USB_SPEED_BPS":
                        if let v = UInt64(val) { result.minExpectedUsbSpeedBps = v }
                    case "TELEGRAM_BOT_TOKEN":
                        foundToken = val
                    case "TELEGRAM_CHAT_ID":
                        foundChatId = val
                        result.telegramChatId = val
                    case "WEBHOOK_URL":
                        foundWebhook = val
                        result.webhookUrl = val
                    case "ALERT_SCRIPT_PATH":
                        result.alertScriptPath = val
                    case "TEMP_WARNING_CELSIUS":
                        if let v = Int(val) { result.tempWarningCelsius = v }
                    case "TEMP_CRITICAL_CELSIUS":
                        if let v = Int(val) { result.tempCriticalCelsius = v }
                    case "DISK_USED_WARNING_PERCENT":
                        if let v = Double(val) { result.diskUsedWarningPercent = v }
                    case "DISK_USED_CRITICAL_PERCENT":
                        if let v = Double(val) { result.diskUsedCriticalPercent = v }
                    case "MIN_FREE_SPACE_CRITICAL_GB":
                        if let v = Double(val) { result.minFreeSpaceCriticalGB = v }
                    case "MIN_FREE_SPACE_WARNING_GB":
                        if let v = Double(val) { result.minFreeSpaceWarningGB = v }
                    default:
                        break
                    }
                }
            }
            break // Stop after first valid .env file is loaded
        }
        return (result, foundToken, foundChatId, foundWebhook)
    }

    static func applyEnvironmentVariables(into cfg: DiskHealthConfig, env: [String: String] = ProcessInfo.processInfo.environment) -> DiskHealthConfig {
        var result = cfg
        if let v = env["DISK_HEALTH_VOLUME"], !v.isEmpty { result.targetVolumePath = v }
        if let v = env["DISK_HEALTH_DEVICE"], !v.isEmpty { result.targetDeviceQuery = v }
        if let v = env["MONITOR_ALL_DISKS"], !v.isEmpty {
            result.monitorAllDisks = (v.lowercased() == "true" || v == "1" || v.lowercased() == "yes")
        }
        if let v = env["DISK_HEALTH_TARGETS"], !v.isEmpty {
            result.monitoredTargets = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if let v = env["DISK_HEALTH_REQUIRED_SUBPATHS"], !v.isEmpty {
            result.requiredSubpaths = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if let v = env["ENABLE_ACTIVE_CANARY"], !v.isEmpty {
            result.enableActiveCanary = (v.lowercased() == "true" || v == "1" || v.lowercased() == "yes")
        }
        if let v = env["ENABLE_NATIVE_NOTIFICATIONS"], !v.isEmpty {
            result.enableNativeNotifications = (v.lowercased() == "true" || v == "1" || v.lowercased() == "yes")
        }
        if let v = env["ENABLE_CRITICAL_SOUND_ALERT"], !v.isEmpty {
            result.enableCriticalSoundAlert = (v.lowercased() == "true" || v == "1" || v.lowercased() == "yes")
        }
        if let v = env["SCHEDULED_VERIFY_INTERVAL_HOURS"], let val = Int(v), val >= 0 {
            result.scheduledVerifyIntervalHours = val
        }
        if let v = env["POLL_INTERVAL_SECONDS"], let val = TimeInterval(v), val >= 5.0 { result.pollIntervalSeconds = val }
        if let v = env["ALERT_COOLDOWN_SECONDS"], let val = TimeInterval(v), val >= 0.0 { result.alertCooldownSeconds = val }
        if let v = env["MIN_EXPECTED_USB_SPEED_BPS"], let val = UInt64(v) { result.minExpectedUsbSpeedBps = val }
        if let v = env["TELEGRAM_CHAT_ID"], !v.isEmpty { result.telegramChatId = v }
        if let v = env["WEBHOOK_URL"], !v.isEmpty { result.webhookUrl = v }
        if let v = env["ALERT_SCRIPT_PATH"], !v.isEmpty { result.alertScriptPath = v }
        if let v = env["TEMP_WARNING_CELSIUS"], let val = Int(v) { result.tempWarningCelsius = val }
        if let v = env["TEMP_CRITICAL_CELSIUS"], let val = Int(v) { result.tempCriticalCelsius = val }
        if let v = env["DISK_USED_WARNING_PERCENT"], let val = Double(v) { result.diskUsedWarningPercent = val }
        if let v = env["DISK_USED_CRITICAL_PERCENT"], let val = Double(v) { result.diskUsedCriticalPercent = val }
        if let v = env["MIN_FREE_SPACE_CRITICAL_GB"], let val = Double(v) { result.minFreeSpaceCriticalGB = val }
        if let v = env["MIN_FREE_SPACE_WARNING_GB"], let val = Double(v) { result.minFreeSpaceWarningGB = val }
        if let v = env["DISK_HEALTH_METRICS_ENABLED"], !v.isEmpty {
            result.metricsServerEnabled = (v.lowercased() == "true" || v == "1" || v.lowercased() == "yes")
        }
        if let v = env["DISK_HEALTH_METRICS_PORT"], let val = Int(v), val >= 1024 && val <= 65535 {
            result.metricsServerPort = val
        }
        if let v = env["DISK_HEALTH_PRE_SLEEP_SHIELD"], !v.isEmpty {
            result.preSleepShieldEnabled = (v.lowercased() == "true" || v == "1" || v.lowercased() == "yes")
        }
        return result
    }

    // In-memory override for CLI invocations (does not mutate config.json)
    func overrideTarget(volumePath: String?, deviceQuery: String?) {
        configLock.lock()
        var next = self._config
        next.targetVolumePath = volumePath
        next.targetDeviceQuery = deviceQuery
        self._config = next
        configLock.unlock()
        notifyObjectWillChangeOnMain()
    }

    func overrideMonitorAll(_ all: Bool) {
        configLock.lock()
        var next = self._config
        next.monitorAllDisks = all
        self._config = next
        configLock.unlock()
        notifyObjectWillChangeOnMain()
    }

    func setMonitorAllDisks(_ all: Bool) {
        updateConfig { cfg in
            cfg.monitorAllDisks = all
        }
    }

    func setMetricsServer(enabled: Bool, port: Int) {
        updateConfig { cfg in
            cfg.metricsServerEnabled = enabled
            cfg.metricsServerPort = max(1024, min(port, 65535))
        }
    }

    func setPreSleepShield(enabled: Bool) {
        updateConfig { cfg in
            cfg.preSleepShieldEnabled = enabled
        }
    }

    func toggleTargetInMonitoredList(_ target: String) {
        updateConfig { cfg in
            if let idx = cfg.monitoredTargets.firstIndex(of: target) {
                cfg.monitoredTargets.remove(at: idx)
            } else {
                cfg.monitoredTargets.append(target)
            }
        }
    }

    // Persistent target update (e.g. from Menu Bar UI dropdown)
    func updateTarget(volumePath: String?, deviceQuery: String?) {
        updateConfig {
            $0.targetVolumePath = volumePath
            $0.targetDeviceQuery = deviceQuery
        }
    }

    func updateConfig(_ updater: (inout DiskHealthConfig) -> Void) {
        configLock.lock()
        updater(&self.persistedConfig)
        self.persistedConfig = self.persistedConfig.validated()
        SecretStore.shared.useKeychainOptIn = self.persistedConfig.useKeychainStorage
        if ConfigManager.isRealSecretToken(self.persistedConfig.telegramBotToken) {
            _ = SecretStore.shared.setSecret(self.persistedConfig.telegramBotToken, forKey: "telegramBotToken", allowInteractiveKeychain: false)
            self.dotEnvTelegramToken = nil
            self.persistedConfig.telegramBotToken = "REDACTED_IN_KEYCHAIN"
        }
        if ConfigManager.isRealSecretToken(self.persistedConfig.webhookUrl) {
            _ = SecretStore.shared.setSecret(self.persistedConfig.webhookUrl, forKey: "webhookUrl", allowInteractiveKeychain: false)
            self.dotEnvWebhookUrl = nil
            self.persistedConfig.webhookUrl = "REDACTED_IN_KEYCHAIN"
        }
        saveConfigLocked(self.persistedConfig)

        // Recompute effective config from updated persistedConfig + .env + env
        let (dotConfig, dotToken, dotChat, dotWebhook) = ConfigManager.loadDotEnvWithWebhook(into: self.persistedConfig, configDir: self.configDir)
        if let tok = dotToken { self.dotEnvTelegramToken = tok }
        if let chat = dotChat { self.dotEnvChatId = chat }
        if let hook = dotWebhook, ConfigManager.isRealSecretToken(hook) { self.dotEnvWebhookUrl = hook }
        self._config = ConfigManager.applyEnvironmentVariables(into: dotConfig).validated()
        configLock.unlock()
        notifyObjectWillChangeOnMain()
    }

    func saveConfig() {
        configLock.lock()
        let current = self.persistedConfig
        configLock.unlock()
        ConfigManager.saveSanitizedConfigFile(current, path: configFilePath)
    }

    private func saveConfigLocked(_ cfg: DiskHealthConfig) {
        ConfigManager.saveSanitizedConfigFile(cfg, path: configFilePath)
    }

    private static func saveSanitizedConfigFile(_ cfg: DiskHealthConfig, path: String) {
        var sanitized = cfg
        if !sanitized.telegramBotToken.isEmpty {
            if ConfigManager.isRealSecretToken(sanitized.telegramBotToken) {
                _ = SecretStore.shared.setSecret(sanitized.telegramBotToken, forKey: "telegramBotToken", allowInteractiveKeychain: false)
            }
            sanitized.telegramBotToken = "REDACTED_IN_KEYCHAIN"
        }
        if !sanitized.webhookUrl.isEmpty {
            if ConfigManager.isRealSecretToken(sanitized.webhookUrl) {
                _ = SecretStore.shared.setSecret(sanitized.webhookUrl, forKey: "webhookUrl", allowInteractiveKeychain: false)
            }
            sanitized.webhookUrl = "REDACTED_IN_KEYCHAIN"
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(sanitized)
            if !AtomicFileWriter.writeRestricted(data: data, toPath: path, permissions: 0o600) {
                fputs("saveSanitizedConfigFile failed for \(path)\n", stderr)
            }
        } catch {
            fputs("saveSanitizedConfigFile failed for \(path): \(error.localizedDescription)\n", stderr)
        }
    }

    func exportSanitizedConfigJSON(includeSecrets: Bool = false) -> String {
        configLock.lock()
        var exported = self._config
        configLock.unlock()
        let token = resolvedTelegramBotToken
        let webhook = resolvedWebhookUrl
        if includeSecrets {
            exported.telegramBotToken = token
            exported.webhookUrl = webhook
        } else {
            exported.telegramBotToken = token.isEmpty ? "" : "•••••••• (Protected)"
            exported.webhookUrl = webhook.isEmpty ? "" : "•••••••• (Protected)"
        }
        if exported.telegramChatId.isEmpty {
            exported.telegramChatId = resolvedTelegramChatId
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(exported), let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }

    @discardableResult
    func importConfig(from data: Data) -> Bool {
        guard let imported = try? JSONDecoder().decode(DiskHealthConfig.self, from: data) else {
            return false
        }
        updateConfig { cfg in
            let existingToken = cfg.telegramBotToken
            let existingWebhook = cfg.webhookUrl
            cfg = imported
            if imported.telegramBotToken.isEmpty || imported.telegramBotToken.contains("Protected") || imported.telegramBotToken == "REDACTED_IN_KEYCHAIN" {
                cfg.telegramBotToken = existingToken
            }
            if imported.webhookUrl.isEmpty || imported.webhookUrl.contains("Protected") || imported.webhookUrl == "REDACTED_IN_KEYCHAIN" {
                cfg.webhookUrl = existingWebhook
            }
        }
        return true
    }

    @discardableResult
    func importConfigFile(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return importConfig(from: data)
    }

    private let logLock = NSLock()
    private let maxLogFileBytes: Int64 = 5 * 1024 * 1024 // 5 MB
    private var lastLoggedMessage: String = ""
    private var lastLoggedTimestamp: Date = .distantPast
    private var isParentDirVerified: Bool = false

    private static let telegramBotRegex = try? NSRegularExpression(pattern: "bot[0-9]{5,}:[A-Za-z0-9_-]{15,}")
    private static let tokenRegex = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9])[0-9]{6,}:[A-Za-z0-9_-]{20,}")
    private static let webhookRegex = try? NSRegularExpression(pattern: "https?://[^\\s\"']+/webhooks/[^\\s\"']+")
    private static let slackWebhookRegex = try? NSRegularExpression(pattern: "https?://hooks\\.slack\\.com/services/[^\\s\"']+")

    static func redactSensitiveLogText(_ text: String) -> String {
        guard text.contains("bot") || text.contains("http") || text.contains(":") else {
            return text
        }
        var sanitized = text
        if let regex = telegramBotRegex {
            sanitized = regex.stringByReplacingMatches(in: sanitized, range: NSRange(location: 0, length: sanitized.utf16.count), withTemplate: "bot<REDACTED_TOKEN>")
        }
        if let regex = tokenRegex {
            sanitized = regex.stringByReplacingMatches(in: sanitized, range: NSRange(location: 0, length: sanitized.utf16.count), withTemplate: "<REDACTED_TOKEN>")
        }
        if let regex = webhookRegex {
            sanitized = regex.stringByReplacingMatches(in: sanitized, range: NSRange(location: 0, length: sanitized.utf16.count), withTemplate: "https://<REDACTED_WEBHOOK_URL>")
        }
        if let regex = slackWebhookRegex {
            sanitized = regex.stringByReplacingMatches(in: sanitized, range: NSRange(location: 0, length: sanitized.utf16.count), withTemplate: "https://hooks.slack.com/services/<REDACTED>")
        }
        return sanitized
    }

    func log(_ message: String, deduplicateBurstWindow: TimeInterval = 2.0) {
        logLock.lock()
        defer { logLock.unlock() }

        let redactedMessage = ConfigManager.redactSensitiveLogText(message)
        let now = Date()
        if deduplicateBurstWindow > 0,
           redactedMessage == lastLoggedMessage,
           now.timeIntervalSince(lastLoggedTimestamp) < deduplicateBurstWindow {
            return
        }
        lastLoggedMessage = redactedMessage
        lastLoggedTimestamp = now

        let line = "[\(isoTimestampFormatter.string(from: now))] \(redactedMessage)\n"
        guard let data = line.data(using: .utf8) else { return }

        if !isParentDirVerified {
            let fm = FileManager.default
            let parentDir = (logFilePath as NSString).deletingLastPathComponent
            if !fm.fileExists(atPath: parentDir) {
                try? fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
            }
            isParentDirVerified = true
        }

        var fd = open(logFilePath, O_CREAT | O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd >= 0 {
            let currentSize = lseek(fd, 0, SEEK_END)
            if currentSize > maxLogFileBytes {
                close(fd)
                let fm = FileManager.default
                let rotatedPath = "\(logFilePath).1"
                try? fm.removeItem(atPath: rotatedPath)
                try? fm.moveItem(atPath: logFilePath, toPath: rotatedPath)
                fd = open(logFilePath, O_CREAT | O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
            }
        }

        if fd >= 0 {
            fchmod(fd, 0o600)
            data.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else { return }
                var bytesWritten = 0
                let totalBytes = data.count
                while bytesWritten < totalBytes {
                    let rc = write(fd, base.advanced(by: bytesWritten), totalBytes - bytesWritten)
                    if rc < 0 {
                        if errno == EINTR { continue }
                        break
                    }
                    bytesWritten += rc
                }
            }
            close(fd)
        }
    }
}
