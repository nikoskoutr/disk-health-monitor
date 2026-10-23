# Configuration & Logging System (`src/config/`)

This directory manages configuration resolution, user preferences, environment overrides, credential redaction, and structured runtime logging.

---

## Files

### [`ConfigManager.swift`](ConfigManager.swift)

#### 1. `DiskHealthConfig`
Codable schema managing 23 runtime parameters and alert thresholds:
- **Targeting & Probing**: `targetVolumePath`, `targetDeviceQuery`, `monitorAllDisks`, `monitoredTargets`, `requiredSubpaths`, `enableActiveCanary`, `pollIntervalSeconds`.
- **Thresholds**: `tempWarningCelsius` (58°C), `tempCriticalCelsius` (68°C), `diskUsedWarningPercent` (85%), `diskUsedCriticalPercent` (93%), `minFreeSpaceWarningGB` (30 GB), `minFreeSpaceCriticalGB` (15 GB), `minExpectedUsbSpeedBps` (5 Gbps).
- **Notifications & Security**: `enableNativeNotifications`, `enableCriticalSoundAlert`, `useKeychainStorage`, `telegramBotToken`, `telegramChatId`, `webhookUrl`, `alertScriptPath`, `alertCooldownSeconds` (3600s).
- **Diagnostics**: `scheduledVerifyIntervalHours` (0 = manual).

#### 2. Configuration Precedence Hierarchy
Configuration values resolve in strict priority order (highest to lowest):
1. **CLI Flags** (`--volume`, `--device`, `--deep`)
2. **Process Environment Variables** (all 20 variables supported)
3. **Local `.env` File** (`$DISK_HEALTH_ENV_FILE`, `~/.config/disk-health-monitor/.env`, or `./.env`)
4. **JSON Configuration File** (`~/.config/disk-health-monitor/config.json`)
5. **Compiled Defaults**

#### 3. Security, Redaction & Profiles
- **Keychain Offloading**: Sensitive tokens (`telegramBotToken`, `webhookUrl`) are offloaded to `SecretStore` (Keychain) and replaced in `config.json` with `"REDACTED_IN_KEYCHAIN"`.
- **Masked Export**: `exportSanitizedConfigJSON(includeSecrets:)` masks tokens as `"•••••••• (Protected)"` unless explicitly exported with `--unmasked`.
- **Profile Import**: `importConfigFile(at:)` validates and merges external configuration JSON profiles without overwriting Keychain credentials.

#### 4. Thread-Safe Structured Logging
- Appends timestamped events (`[YYYY-MM-DD HH:MM:SS] message`) to `logs/health.log` after automatically redacting Telegram bot tokens and webhook URLs and deduplicating identical burst messages within a 2-second window.
- Uses atomic POSIX flags `O_CREAT | O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC` with `0600` permissions protected by `NSLock`.
- Checks file size via `lseek(fd, 0, SEEK_END)` on the open file descriptor and rotates log files when exceeding 5 MB (`health.log.1`).
