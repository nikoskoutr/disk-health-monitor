import Foundation
import Combine

// MARK: - Universal Configuration

struct DiskHealthConfig: Codable, Equatable {
    var targetVolumePath: String? = nil
    var targetDeviceQuery: String? = nil
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
    var telegramBotToken: String = ""
    var telegramChatId: String = ""

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = DiskHealthConfig()
        targetVolumePath = try container.decodeIfPresent(String.self, forKey: .targetVolumePath) ?? defaults.targetVolumePath
        targetDeviceQuery = try container.decodeIfPresent(String.self, forKey: .targetDeviceQuery) ?? defaults.targetDeviceQuery
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
        telegramBotToken = try container.decodeIfPresent(String.self, forKey: .telegramBotToken) ?? defaults.telegramBotToken
        telegramChatId = try container.decodeIfPresent(String.self, forKey: .telegramChatId) ?? defaults.telegramChatId
    }
}

final class ConfigManager: ObservableObject {
    static let shared = ConfigManager()

    let configDir: String
    let logsDir: String

    var stateFilePath: String { "\(logsDir)/state.json" }
    var configFilePath: String { "\(configDir)/config.json" }
    var logFilePath: String { "\(logsDir)/health.log" }
    var latestJsonPath: String { "\(logsDir)/latest_status.json" }

    @Published var config: DiskHealthConfig
    private(set) var dotEnvTelegramToken: String? = nil
    private(set) var dotEnvChatId: String? = nil

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let currentDir = FileManager.default.currentDirectoryPath
        let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent().path

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

        // 2. Resolve Logs Directory
        if let envLogsDir = ProcessInfo.processInfo.environment["DISK_HEALTH_LOGS_DIR"], !envLogsDir.isEmpty {
            self.logsDir = (envLogsDir as NSString).standardizingPath
        } else {
            let candidateRepoLogs = "\(currentDir)/logs"
            let candidateBundleLogs = "\(bundleParent)/logs"
            let isCurrentDirRepo = FileManager.default.fileExists(atPath: "\(currentDir)/src/bridge/DiskHealthBridge.c") ||
                                   FileManager.default.fileExists(atPath: "\(currentDir)/build_and_install.sh")
            let isBundleParentRepo = FileManager.default.fileExists(atPath: "\(bundleParent)/src/bridge/DiskHealthBridge.c") ||
                                     FileManager.default.fileExists(atPath: "\(bundleParent)/build_and_install.sh")

            if FileManager.default.fileExists(atPath: candidateRepoLogs) ||
               (isCurrentDirRepo && (try? FileManager.default.createDirectory(atPath: candidateRepoLogs, withIntermediateDirectories: true)) != nil) {
                self.logsDir = candidateRepoLogs
            } else if FileManager.default.fileExists(atPath: candidateBundleLogs) ||
                      (isBundleParentRepo && (try? FileManager.default.createDirectory(atPath: candidateBundleLogs, withIntermediateDirectories: true)) != nil) {
                self.logsDir = candidateBundleLogs
            } else {
                self.logsDir = "\(self.configDir)/logs"
            }
        }
        try? FileManager.default.createDirectory(atPath: self.logsDir, withIntermediateDirectories: true)

        // 3. Load JSON configuration
        var initialConfig = DiskHealthConfig()
        let configPath = "\(self.configDir)/config.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
           let decoded = try? JSONDecoder().decode(DiskHealthConfig.self, from: data) {
            initialConfig = decoded
        }

        // 4. Migrate plaintext Telegram Bot Token into SecretStore
        if ConfigManager.isRealSecretToken(initialConfig.telegramBotToken) {
            _ = SecretStore.shared.setSecret(initialConfig.telegramBotToken, forKey: "telegramBotToken")
            initialConfig.telegramBotToken = "REDACTED_IN_KEYCHAIN"
            ConfigManager.saveSanitizedConfigFile(initialConfig, path: configPath)
        }

        // 5. Apply .env configuration (runtime overrides without mutating persisted secrets)
        let (dotConfig, dotToken, dotChat) = ConfigManager.loadDotEnv(into: initialConfig, configDir: self.configDir)
        self.dotEnvTelegramToken = dotToken
        self.dotEnvChatId = dotChat

        // 6. Apply Environment variables
        initialConfig = ConfigManager.applyEnvironmentVariables(into: dotConfig)

        self.config = initialConfig

        // Enforce 0600 on config.json if it exists
        if FileManager.default.fileExists(atPath: configPath) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath)
        }
    }

    private static func isRealSecretToken(_ token: String) -> Bool {
        return !token.isEmpty &&
               token != "REDACTED_IN_KEYCHAIN" &&
               token != "Stored in Keychain" &&
               !token.contains("Protected")
    }

    var resolvedTelegramBotToken: String {
        if let envToken = ProcessInfo.processInfo.environment["TELEGRAM_BOT_TOKEN"], !envToken.isEmpty {
            return envToken
        }
        if let dotToken = dotEnvTelegramToken, !dotToken.isEmpty {
            return dotToken
        }
        if let secret = SecretStore.shared.getSecret(forKey: "telegramBotToken"), !secret.isEmpty {
            return secret
        }
        if ConfigManager.isRealSecretToken(config.telegramBotToken) {
            return config.telegramBotToken
        }
        return ""
    }

    var resolvedTelegramChatId: String {
        if let envChat = ProcessInfo.processInfo.environment["TELEGRAM_CHAT_ID"], !envChat.isEmpty {
            return envChat
        }
        if !config.telegramChatId.isEmpty {
            return config.telegramChatId
        }
        if let dotChat = dotEnvChatId, !dotChat.isEmpty {
            return dotChat
        }
        return ""
    }

    private static func loadDotEnv(into cfg: DiskHealthConfig, configDir: String) -> (DiskHealthConfig, String?, String?) {
        var result = cfg
        var foundToken: String? = nil
        var foundChatId: String? = nil
        let currentDir = FileManager.default.currentDirectoryPath
        let bundleDir = Bundle.main.bundleURL.deletingLastPathComponent().path

        var searchPaths: [String] = []
        if let customEnv = ProcessInfo.processInfo.environment["DISK_HEALTH_ENV_FILE"], !customEnv.isEmpty {
            searchPaths.append((customEnv as NSString).standardizingPath)
        }
        searchPaths.append("\(configDir)/.env")
        if ProcessInfo.processInfo.environment["DISK_HEALTH_CONFIG_DIR"]?.isEmpty ?? true {
            searchPaths.append("\(currentDir)/.env")
            searchPaths.append("\(bundleDir)/.env")
        }

        for path in searchPaths {
            guard FileManager.default.fileExists(atPath: path),
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
                    case "TELEGRAM_BOT_TOKEN":
                        foundToken = val
                    case "TELEGRAM_CHAT_ID":
                        foundChatId = val
                        if result.telegramChatId.isEmpty { result.telegramChatId = val }
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
        return (result, foundToken, foundChatId)
    }

    private static func applyEnvironmentVariables(into cfg: DiskHealthConfig) -> DiskHealthConfig {
        var result = cfg
        let env = ProcessInfo.processInfo.environment
        if let v = env["DISK_HEALTH_VOLUME"], !v.isEmpty { result.targetVolumePath = v }
        if let v = env["DISK_HEALTH_DEVICE"], !v.isEmpty { result.targetDeviceQuery = v }
        if let v = env["TELEGRAM_CHAT_ID"], !v.isEmpty && result.telegramChatId.isEmpty { result.telegramChatId = v }
        if let v = env["TEMP_WARNING_CELSIUS"], let val = Int(v) { result.tempWarningCelsius = val }
        if let v = env["TEMP_CRITICAL_CELSIUS"], let val = Int(v) { result.tempCriticalCelsius = val }
        if let v = env["DISK_USED_WARNING_PERCENT"], let val = Double(v) { result.diskUsedWarningPercent = val }
        if let v = env["DISK_USED_CRITICAL_PERCENT"], let val = Double(v) { result.diskUsedCriticalPercent = val }
        if let v = env["MIN_FREE_SPACE_CRITICAL_GB"], let val = Double(v) { result.minFreeSpaceCriticalGB = val }
        if let v = env["MIN_FREE_SPACE_WARNING_GB"], let val = Double(v) { result.minFreeSpaceWarningGB = val }
        return result
    }

    // In-memory override for CLI invocations (does not mutate config.json)
    func overrideTarget(volumePath: String?, deviceQuery: String?) {
        config.targetVolumePath = volumePath
        config.targetDeviceQuery = deviceQuery
    }

    // Persistent target update (e.g. from Menu Bar UI dropdown)
    func updateTarget(volumePath: String?, deviceQuery: String?) {
        updateConfig {
            $0.targetVolumePath = volumePath
            $0.targetDeviceQuery = deviceQuery
        }
    }

    func updateConfig(_ updater: (inout DiskHealthConfig) -> Void) {
        updater(&self.config)
        if ConfigManager.isRealSecretToken(self.config.telegramBotToken) {
            _ = SecretStore.shared.setSecret(self.config.telegramBotToken, forKey: "telegramBotToken")
            self.dotEnvTelegramToken = nil
            self.config.telegramBotToken = "REDACTED_IN_KEYCHAIN"
        }
        saveConfig()
    }

    func saveConfig() {
        ConfigManager.saveSanitizedConfigFile(self.config, path: configFilePath)
    }

    private static func saveSanitizedConfigFile(_ cfg: DiskHealthConfig, path: String) {
        var sanitized = cfg
        if !sanitized.telegramBotToken.isEmpty {
            if ConfigManager.isRealSecretToken(sanitized.telegramBotToken) {
                _ = SecretStore.shared.setSecret(sanitized.telegramBotToken, forKey: "telegramBotToken")
            }
            sanitized.telegramBotToken = "REDACTED_IN_KEYCHAIN"
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(sanitized)
            let url = URL(fileURLWithPath: path)
            let parentDir = url.deletingLastPathComponent().path
            try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            fputs("saveSanitizedConfigFile failed for \(path): \(error.localizedDescription)\n", stderr)
        }
    }

    func exportSanitizedConfigJSON(includeSecrets: Bool = false) -> String {
        var exported = self.config
        let token = resolvedTelegramBotToken
        if includeSecrets {
            exported.telegramBotToken = token
        } else {
            exported.telegramBotToken = token.isEmpty ? "" : "•••••••• (Protected)"
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
            cfg = imported
            if imported.telegramBotToken.isEmpty || imported.telegramBotToken.contains("Protected") || imported.telegramBotToken == "REDACTED_IN_KEYCHAIN" {
                cfg.telegramBotToken = existingToken
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
    private let maxLogFileBytes: UInt64 = 5 * 1024 * 1024 // 5 MB

    func log(_ message: String) {
        logLock.lock()
        defer { logLock.unlock() }

        let line = "[\(isoTimestampFormatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        let fm = FileManager.default
        let parentDir = (logFilePath as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: parentDir) {
            try? fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        }

        if fm.fileExists(atPath: logFilePath) {
            if let attrs = try? fm.attributesOfItem(atPath: logFilePath),
               let fileSize = attrs[.size] as? UInt64,
               fileSize > maxLogFileBytes {
                let rotatedPath = "\(logFilePath).1"
                try? fm.removeItem(atPath: rotatedPath)
                try? fm.moveItem(atPath: logFilePath, toPath: rotatedPath)
            }
        }

        if fm.fileExists(atPath: logFilePath), let handle = FileHandle(forWritingAtPath: logFilePath) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: logFilePath), options: .atomic)
        }
    }
}
