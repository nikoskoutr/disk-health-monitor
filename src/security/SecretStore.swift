import Foundation
import Security

// MARK: - Keychain Security & Secret Management

final class SecretStore {
    static let shared = SecretStore()
    private let serviceName = "io.github.disk-health-monitor"
    private let lock = NSRecursiveLock()
    private var _configDir: String? = nil

    var configDir: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _configDir
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _configDir = newValue
        }
    }

    private var isCustomConfigDirOverride: Bool {
        if let env = ProcessInfo.processInfo.environment["DISK_HEALTH_CONFIG_DIR"], !env.isEmpty {
            return true
        }
        return false
    }

    private var fallbackSecretsPath: String {
        let base: String
        if let dir = configDir, !dir.isEmpty {
            base = dir
        } else if let env = ProcessInfo.processInfo.environment["DISK_HEALTH_CONFIG_DIR"], !env.isEmpty {
            base = (env as NSString).standardizingPath
        } else {
            base = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.config/disk-health-monitor"
        }
        return "\(base)/.secrets.json"
    }

    private init() {}

    @discardableResult
    func setSecret(_ value: String, forKey key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value.isEmpty {
            return deleteSecret(forKey: key)
        }

        guard let data = value.data(using: .utf8) else { return false }

        var keychainSuccess = false
        if !isCustomConfigDirOverride {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: key
            ]

            let status = SecItemCopyMatching(query as CFDictionary, nil)
            if status == errSecSuccess {
                let updateAttrs: [String: Any] = [
                    kSecValueData as String: data
                ]
                let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
                if updateStatus == errSecSuccess {
                    keychainSuccess = true
                } else {
                    // If ad-hoc signature changed across rebuilds, recreate the item
                    _ = SecItemDelete(query as CFDictionary)
                    var newQuery = query
                    newQuery[kSecValueData as String] = data
                    newQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                    keychainSuccess = (SecItemAdd(newQuery as CFDictionary, nil) == errSecSuccess)
                }
            } else if status == errSecItemNotFound {
                var newQuery = query
                newQuery[kSecValueData as String] = data
                newQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                let addStatus = SecItemAdd(newQuery as CFDictionary, nil)
                keychainSuccess = (addStatus == errSecSuccess)
            }
        }

        if keychainSuccess {
            // Remove any stale plaintext copy from fallback file if Keychain succeeded
            var secrets = loadFallbackSecrets()
            if secrets.removeValue(forKey: key) != nil {
                saveFallbackSecrets(secrets)
            }
            return true
        }

        // Only write to 0600 fallback file in headless/SSH environments or custom test sandboxes
        var secrets = loadFallbackSecrets()
        secrets[key] = value
        return saveFallbackSecrets(secrets)
    }

    func getSecret(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if isCustomConfigDirOverride {
            let fallback = loadFallbackSecrets()
            if let val = fallback[key], !val.isEmpty {
                return val
            }
            return nil
        }

        // 1. Try macOS Keychain first
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, let str = String(data: data, encoding: .utf8), !str.isEmpty {
            return str
        }

        // 2. Fallback file (headless / non-Keychain environments)
        let fallback = loadFallbackSecrets()
        if let val = fallback[key], !val.isEmpty {
            return val
        }

        return nil
    }

    @discardableResult
    func deleteSecret(forKey key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let kcDeleted = isCustomConfigDirOverride ? true : deleteSecretFromKeychain(key: key)
        var secrets = loadFallbackSecrets()
        secrets.removeValue(forKey: key)
        saveFallbackSecrets(secrets)
        return kcDeleted
    }

    private func deleteSecretFromKeychain(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private func loadFallbackSecrets() -> [String: String] {
        let path = fallbackSecretsPath
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return json
    }

    @discardableResult
    private func saveFallbackSecrets(_ secrets: [String: String]) -> Bool {
        let path = fallbackSecretsPath
        if secrets.isEmpty {
            try? FileManager.default.removeItem(atPath: path)
            return true
        }
        let url = URL(fileURLWithPath: path)
        let parentDir = url.deletingLastPathComponent().path
        do {
            try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parentDir)
            let data = try JSONEncoder().encode(secrets)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return true
        } catch {
            return false
        }
    }
}
