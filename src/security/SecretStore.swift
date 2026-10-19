import Foundation
import Security

// MARK: - Keychain Security & Secret Management

final class SecretStore {
    static let shared = SecretStore()
    private let serviceName = "io.github.disk-health-monitor"
    var configDir: String? = nil

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

        // Keep local fallback store synchronized with 0600 POSIX permissions
        var secrets = loadFallbackSecrets()
        secrets[key] = value
        saveFallbackSecrets(secrets)

        return keychainSuccess || true
    }

    func getSecret(forKey key: String) -> String? {
        // 1. Check synchronized 0600 fallback store first when using custom config dir or when updated locally
        let fallback = loadFallbackSecrets()
        if isCustomConfigDirOverride {
            if let val = fallback[key], !val.isEmpty {
                return val
            }
            return nil
        }

        // 2. Try macOS Keychain
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
            if let fbVal = fallback[key], !fbVal.isEmpty, fbVal != str {
                return fbVal
            }
            return str
        }

        // 3. Fallback file
        if let val = fallback[key], !val.isEmpty {
            return val
        }

        return nil
    }

    @discardableResult
    func deleteSecret(forKey key: String) -> Bool {
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

    private func saveFallbackSecrets(_ secrets: [String: String]) {
        let path = fallbackSecretsPath
        if secrets.isEmpty {
            try? FileManager.default.removeItem(atPath: path)
            return
        }
        let url = URL(fileURLWithPath: path)
        let parentDir = url.deletingLastPathComponent().path
        try? FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parentDir)
        if let data = try? JSONEncoder().encode(secrets) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }
}
