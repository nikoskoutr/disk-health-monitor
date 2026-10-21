import Foundation
import Security

// MARK: - Keychain Integration State Machine

enum KeychainIntegrationState: Equatable, Sendable {
    case localOnlyDefault
    case keychainLockedOrUnverified
    case keychainReadyAndUnlocked
    case accessDenied(Int32)
    case error(Int32)

    var statusBadgeText: String {
        switch self {
        case .localOnlyDefault:
            return "Local Restricted Storage (.env / .secrets.json 0600)"
        case .keychainLockedOrUnverified:
            return "macOS Keychain (Locked — Click Unlock to Read)"
        case .keychainReadyAndUnlocked:
            return "macOS Keychain (Unlocked & Active)"
        case .accessDenied:
            return "Keychain Access Denied — Using Local .secrets.json (0600)"
        case .error(let code):
            return "Keychain Unavailable (OSStatus \(code)) — Using .secrets.json (0600)"
        }
    }

    var isAccessDenied: Bool {
        if case .accessDenied = self { return true }
        return false
    }
}

// MARK: - Keychain Security & Secret Management

final class SecretStore: @unchecked Sendable {
    static let shared = SecretStore()
    private let serviceName = "io.github.disk-health-monitor"
    private let lock = NSRecursiveLock()
    private var _configDir: String? = nil
    private var _keychainState: KeychainIntegrationState = .localOnlyDefault
    private var _useKeychainOptIn: Bool = false
    private var sessionKeychainCache: [String: String] = [:]

    /// Test injection hook to simulate macOS Keychain OSStatus responses (e.g. errSecAuthFailed / -25293 or errSecUserCanceled / -128) without triggering a GUI modal dialog during automated tests.
    var simulatedKeychainStatusForTesting: OSStatus? = nil

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

    var keychainState: KeychainIntegrationState {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _keychainState
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _keychainState = newValue
        }
    }

    var useKeychainOptIn: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _useKeychainOptIn
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _useKeychainOptIn = newValue
            if !newValue && !_keychainState.isAccessDenied {
                _keychainState = .localOnlyDefault
            } else if newValue && _keychainState == .localOnlyDefault {
                _keychainState = .keychainLockedOrUnverified
            }
        }
    }

    private var isCustomConfigDirOverride: Bool {
        if let env = ProcessInfo.processInfo.environment["DISK_HEALTH_CONFIG_DIR"], !env.isEmpty {
            return true
        }
        return false
    }

    var fallbackSecretsPath: String {
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

    /// Reset session cache and state for unit tests.
    func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        simulatedKeychainStatusForTesting = nil
        sessionKeychainCache.removeAll()
        _useKeychainOptIn = false
        _keychainState = .localOnlyDefault
    }

    /// Stores a secret.
    /// - IMPORTANT: By default (`allowInteractiveKeychain == false`), this writes ONLY to the local `0600` `.secrets.json` file (and updates the in-memory session cache) so it NEVER triggers an unprompted macOS Keychain popup.
    /// - If `allowInteractiveKeychain == true` (called when user explicitly clicks "Onboard to Keychain"), it writes to the macOS Keychain and handles denial gracefully.
    @discardableResult
    func setSecret(_ value: String, forKey key: String, allowInteractiveKeychain: Bool = false) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if value.isEmpty {
            return deleteSecret(forKey: key, allowInteractiveKeychain: allowInteractiveKeychain)
        }

        sessionKeychainCache[key] = value

        // Always persist to 0600 fallback file first so credentials are never lost even if Keychain is denied or locked
        var secrets = loadFallbackSecrets()
        secrets[key] = value
        let localSaved = saveFallbackSecrets(secrets)

        guard allowInteractiveKeychain && _useKeychainOptIn else {
            return localSaved
        }

        let kcResult = writeSecretToKeychainInteractiveLocked(value, forKey: key)
        switch kcResult {
        case .success:
            return true
        case .failure:
            // Fallback file already saved above; return localSaved so caller never breaks
            return localSaved
        }
    }

    /// Reads a secret without EVER triggering an unprompted macOS Keychain modal dialog.
    /// Only reads from macOS Keychain if `allowInteractiveKeychain == true` (explicit user button click).
    func getSecret(forKey key: String, allowInteractiveKeychain: Bool = false) -> String? {
        lock.lock()
        defer { lock.unlock() }

        // 1. Check in-memory session cache first
        if let cached = sessionKeychainCache[key], !cached.isEmpty {
            return cached
        }

        // 2. Check local 0600 .secrets.json file (Zero Keychain popups)
        let fallback = loadFallbackSecrets()
        if let val = fallback[key], !val.isEmpty {
            sessionKeychainCache[key] = val
            return val
        }

        // 3. Only query macOS Keychain if explicitly requested by user interaction
        guard allowInteractiveKeychain && _useKeychainOptIn else {
            return nil
        }

        if let simulated = simulatedKeychainStatusForTesting {
            handleKeychainFailureStatusLocked(simulated)
            return nil
        }

        guard !isCustomConfigDirOverride else {
            return nil
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess,
           let data = item as? Data,
           let str = String(data: data, encoding: .utf8),
           !str.isEmpty {
            sessionKeychainCache[key] = str
            _keychainState = .keychainReadyAndUnlocked
            return str
        } else if status != errSecItemNotFound {
            handleKeychainFailureStatusLocked(status)
        }

        return nil
    }

    /// Explicit User Action: Onboards the provided secrets into macOS Keychain (or unlocks existing ones).
    /// If the user clicks "Deny" or cancels the system dialog, transitions cleanly to `.accessDenied` and falls back to `.secrets.json` (0600).
    func onboardOrUnlockKeychainInteractive(secretsToStore: [String: String]) -> Result<KeychainIntegrationState, DiskHealthError> {
        lock.lock()
        defer { lock.unlock() }

        _useKeychainOptIn = true

        // Always ensure non-empty secrets are saved in local 0600 fallback first so nothing is lost on Deny
        var localSecrets = loadFallbackSecrets()
        for (k, v) in secretsToStore where !v.isEmpty {
            localSecrets[k] = v
            sessionKeychainCache[k] = v
        }
        saveFallbackSecrets(localSecrets)

        if let simulated = simulatedKeychainStatusForTesting {
            if simulated == errSecSuccess {
                _keychainState = .keychainReadyAndUnlocked
                return .success(.keychainReadyAndUnlocked)
            } else {
                let err = handleKeychainFailureStatusLocked(simulated)
                return .failure(err)
            }
        }

        if isCustomConfigDirOverride {
            _keychainState = .keychainReadyAndUnlocked
            return .success(.keychainReadyAndUnlocked)
        }

        // Write any non-empty secrets to Keychain interactively
        for (key, val) in localSecrets where !val.isEmpty {
            let res = writeSecretToKeychainInteractiveLocked(val, forKey: key)
            if case .failure(let err) = res {
                return .failure(err)
            }
        }

        // Also attempt to read telegramBotToken and webhookUrl from Keychain if local was empty
        for key in ["telegramBotToken", "webhookUrl"] where (localSecrets[key] ?? "").isEmpty {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: key,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess,
               let data = item as? Data,
               let str = String(data: data, encoding: .utf8),
               !str.isEmpty {
                sessionKeychainCache[key] = str
                localSecrets[key] = str
                saveFallbackSecrets(localSecrets)
            } else if status != errSecItemNotFound && status != errSecSuccess {
                let err = handleKeychainFailureStatusLocked(status)
                return .failure(err)
            }
        }

        _keychainState = .keychainReadyAndUnlocked
        return .success(.keychainReadyAndUnlocked)
    }

    /// Disables macOS Keychain integration and uses strictly `.secrets.json` (0600) + `.env`.
    func switchToLocalRestrictedStorageOnly() {
        lock.lock()
        defer { lock.unlock() }
        _useKeychainOptIn = false
        _keychainState = .localOnlyDefault
    }

    @discardableResult
    func deleteSecret(forKey key: String, allowInteractiveKeychain: Bool = false) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        sessionKeychainCache.removeValue(forKey: key)

        var secrets = loadFallbackSecrets()
        secrets.removeValue(forKey: key)
        let localOk = saveFallbackSecrets(secrets)

        if allowInteractiveKeychain && _useKeychainOptIn && !isCustomConfigDirOverride && simulatedKeychainStatusForTesting == nil {
            _ = deleteSecretFromKeychainLocked(key: key)
        }
        return localOk
    }

    // MARK: - Private Keychain Helpers (Must be called with lock held)

    private func writeSecretToKeychainInteractiveLocked(_ value: String, forKey key: String) -> Result<Void, DiskHealthError> {
        guard let data = value.data(using: .utf8) else {
            return .failure(.secretStoreFailure(key: key))
        }

        if let simulated = simulatedKeychainStatusForTesting {
            if simulated == errSecSuccess {
                _keychainState = .keychainReadyAndUnlocked
                return .success(())
            } else {
                return .failure(handleKeychainFailureStatusLocked(simulated))
            }
        }

        if isCustomConfigDirOverride {
            _keychainState = .keychainReadyAndUnlocked
            return .success(())
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let updateAttrs: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
            if updateStatus == errSecSuccess {
                _keychainState = .keychainReadyAndUnlocked
                return .success(())
            } else if isUserDeniedOrCancelled(updateStatus) {
                return .failure(handleKeychainFailureStatusLocked(updateStatus))
            } else {
                // If ad-hoc signature changed across rebuilds, recreate the item
                _ = SecItemDelete(query as CFDictionary)
                var newQuery = query
                newQuery[kSecValueData as String] = data
                newQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                let addStatus = SecItemAdd(newQuery as CFDictionary, nil)
                if addStatus == errSecSuccess {
                    _keychainState = .keychainReadyAndUnlocked
                    return .success(())
                } else {
                    return .failure(handleKeychainFailureStatusLocked(addStatus))
                }
            }
        } else if status == errSecItemNotFound {
            var newQuery = query
            newQuery[kSecValueData as String] = data
            newQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(newQuery as CFDictionary, nil)
            if addStatus == errSecSuccess {
                _keychainState = .keychainReadyAndUnlocked
                return .success(())
            } else {
                return .failure(handleKeychainFailureStatusLocked(addStatus))
            }
        } else {
            return .failure(handleKeychainFailureStatusLocked(status))
        }
    }

    private func isUserDeniedOrCancelled(_ status: OSStatus) -> Bool {
        return status == errSecAuthFailed ||           // -25293 (User clicked Deny or auth failed)
               status == errSecUserCanceled ||         // -128   (User cancelled dialog)
               status == errSecInteractionNotAllowed   // -25308 (Headless / interaction disallowed)
    }

    @discardableResult
    private func handleKeychainFailureStatusLocked(_ status: OSStatus) -> DiskHealthError {
        _useKeychainOptIn = false
        if isUserDeniedOrCancelled(status) {
            _keychainState = .accessDenied(status)
            return .keychainAccessDenied(status: status)
        } else {
            _keychainState = .error(status)
            return .keychainOperationFailed(status: status)
        }
    }

    private func deleteSecretFromKeychainLocked(key: String) -> Bool {
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
