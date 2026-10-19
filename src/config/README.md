# Configuration & Logging System (`src/config/`)

This directory manages user preferences, alert thresholds, environment variable overrides, secret redaction, and structured runtime logging.

---

## Files

### [`ConfigManager.swift`](ConfigManager.swift)

#### 1. `DiskHealthConfig` (`Codable`, `Equatable`)
Defines all configurable runtime parameters and health thresholds with sensible defaults:
- **Drive Targeting & Probing**:
  - `targetVolumePath`: Optional mount path (e.g., `/Volumes/ExternalSSD` or `/`). `nil` triggers auto-discovery.
  - `targetDeviceQuery`: Optional BSD unit (`disk4`), product name, or serial number query.
  - `requiredSubpaths`: Array of relative directory paths that must exist on the target volume when mounted.
  - `enableActiveCanary`: Toggles the active `.disk_health_canary_probe` write/fsync/read test (default: `true`).
  - `pollIntervalSeconds`: Background polling frequency in seconds (default: `30.0`).
- **Notification Channels & Cooldown**:
  - `enableNativeNotifications`: Toggles native macOS Notification Center alerts (default: `true`).
  - `telegramBotToken`: Loaded dynamically from `SecretStore` (macOS Keychain) at runtime; persisted as `"REDACTED_IN_KEYCHAIN"` in `config.json`.
  - `telegramChatId`: Target Telegram chat or channel ID.
  - `alertCooldownSeconds`: Minimum interval in seconds before repeating an identical alert (default: `3600.0` / 1 hour).
- **Health Thresholds**:
  - `tempWarningCelsius` (default: `58°C`) & `tempCriticalCelsius` (default: `68°C`).
  - `diskUsedWarningPercent` (default: `85.0%`) & `diskUsedCriticalPercent` (default: `93.0%`).
  - `minFreeSpaceWarningGB` (default: `30.0 GB`) & `minFreeSpaceCriticalGB` (default: `15.0 GB`).
  - `minExpectedUsbSpeedBps` (default: `5_000_000_000` / 5 Gbps SuperSpeed USB).

#### 2. Multi-Source Precedence Hierarchy
Configuration values are merged in the following priority order (highest to lowest):
1. **CLI Flags** (`--volume`, `--device`, `--deep`)
2. **Process Environment Variables** (`DISK_HEALTH_VOLUME`, `DISK_HEALTH_DEVICE`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`, `TEMP_WARNING_CELSIUS`, `TEMP_CRITICAL_CELSIUS`, `DISK_USED_WARNING_PERCENT`, `DISK_USED_CRITICAL_PERCENT`, `MIN_FREE_SPACE_WARNING_GB`, `MIN_FREE_SPACE_CRITICAL_GB`)
3. **Local `.env` Files** (`$DISK_HEALTH_ENV_FILE`, `~/.config/disk-health-monitor/.env`, or `./.env`)
4. **User JSON Configuration** (`~/.config/disk-health-monitor/config.json`)
5. **Built-In Defaults**

#### 3. Security & Redaction
- **`saveSanitizedConfigFile(_:path:)`**: Saves any real `telegramBotToken` into `SecretStore.shared` (`telegramBotToken`), replaces the field in `config.json` with `"REDACTED_IN_KEYCHAIN"`, and enforces `0600` POSIX permissions on `config.json`.
- **`exportSanitizedConfigJSON(includeSecrets:)`**: Masks `telegramBotToken` as `"•••••••• (Protected)"` by default for `--export-config` and diagnostic bundles, or outputs the unmasked token when `--export-config --unmasked` is explicitly requested.

#### 4. Runtime Directory & Structured Logging
- Resolves the `logs/` directory inside the project workspace (or `~/.config/disk-health-monitor/logs` when running outside a checkout).
- Appends ISO-8601 timestamped entries (`[YYYY-MM-DD HH:MM:SS] message`) to `logs/health.log`.
