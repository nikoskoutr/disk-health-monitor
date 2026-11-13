# Notification Dispatchers (`src/notifications/`)

This directory contains alert dispatchers delivering real-time disk health notifications and recovery alerts across desktop and remote channels.

---

## Files

### 1. [`MacOSNotifier.swift`](MacOSNotifier.swift)
Delivers native macOS alerts via **UserNotifications (`UNUserNotificationCenter`)**:
- Uses the application bundle identifier (`io.github.disk-health-monitor`). Symlink invocations automatically resolve into the parent `.app` bundle.
- Requests `.alert`, `.sound`, and `.badge` permissions.
- Deduplicates active notifications per drive using unique identifiers (`disk-health-alert-<driveKey>`), preventing Notification Center clutter.
- Never invokes `osascript` or Script Editor, guaranteeing clean native notifications.

### 2. [`TelegramNotifier.swift`](TelegramNotifier.swift)
Sends formatted HTML alerts to a Telegram chat or channel:
- **Shared Ephemeral Session**: Single `URLSession` with 15-second timeouts preventing socket leaks.
- **HTML Escaping**: Escapes `&`, `<`, and `>` across all dynamic volume paths, device names, and error strings.
- **Rich Formatting**: Includes severity badges (`🚨`, `⚠️`, `✅`), drive identity, transport speed, temperature, free space, and active issues.
- **Credential Protection**: Redacts bot tokens from all network failure logs.

### 3. [`WebhookNotifier.swift`](WebhookNotifier.swift)
Delivers alerts to multi-platform webhook endpoints:
- **Broad Compatibility**: Formats payloads dynamically for **Discord**, **Slack**, **Mattermost**, **Home Assistant**, or generic JSON endpoints.
- **Sanitized Logging**: Automatically masks webhook URLs and credentials in runtime logs.
- **Non-Blocking**: Asynchronous dispatch with 15-second request timeouts and connectivity testing from the Settings UI.

### 4. [`AlertCoordinator.swift`](AlertCoordinator.swift)
Extracts stateful alert transition tracking and notification delivery from `DiskHealthMonitor`:
- **Transient Poll Hysteresis & Recovery Cooldowns (`ALERT-01`)**: Requires 2 consecutive unhealthy polls for transient latency/thermal-spike warnings, 2 healthy polls for recovery alerts, and preserves 900s cooldowns across brief blips.
- **Baseline Advancement (`RULE-02`)**: Advances error, retry, and `BUS_PHY_ERRORS` baselines atomically upon alert dispatch.
- **Digests & Clean Script Hooks**: Handles scheduled daily digests and executes user alert scripts via `SubprocessRunner` with scrubbed environment variables (`makeCleanAlertScriptEnvironment`).

### 5. Audio Beeps & Script Hooks
- **Audible Alerts**: When `enableCriticalSoundAlert` is enabled, triggers an immediate system audio beep (`NSSound.beep()`) upon entering a critical health state.
- **Custom Shell Hook**: When `alertScriptPath` is configured, executes an external shell script or binary asynchronously with a 15-second watchdog timer, passing issue parameters via environment variables.
