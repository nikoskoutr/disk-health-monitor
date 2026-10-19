# Credential & Secret Management (`src/security/`)

This directory implements secure credential storage for sensitive tokens (such as the Telegram Bot API token) so that secrets are never stored in plain text inside `config.json` or leaked in diagnostic exports.

---

## Files

### [`SecretStore.swift`](SecretStore.swift)

`SecretStore` provides a unified key-value interface (`setSecret(_:forKey:)`, `getSecret(forKey:)`, `deleteSecret(forKey:)`) backed by a two-tier storage strategy:

1. **Primary Tier — macOS Keychain (`Security.framework`)**:
   - Uses `SecItemAdd`, `SecItemCopyMatching`, `SecItemUpdate`, and `SecItemDelete` with `kSecClassGenericPassword`.
   - Service identifier: `com.universal.disk-health-monitor`.
   - Accessibility policy: `kSecAttrAccessibleAfterFirstUnlock` so background `launchd` agents can read notification credentials after the system boots and unlocks once.

2. **Fallback Tier — Restricted `0600` Secret File (`.secrets.json`)**:
   - In headless SSH sessions or sandboxed test environments where Keychain interaction may return an OSStatus error, `SecretStore` automatically falls back to storing the key-value pair in `~/.config/disk-health-monitor/.secrets.json`.
   - Enforces strict POSIX `0600` (`rw-------`, owner-only) file permissions via `FileManager.setAttributes([.posixPermissions: 0o600])` immediately upon creation and update.
   - Whenever a secret is deleted or cleared, it is purged from both the macOS Keychain and the `.secrets.json` fallback file.
