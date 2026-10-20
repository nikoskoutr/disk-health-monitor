# Notification Dispatchers (`src/notifications/`)

This directory contains the notification dispatchers responsible for delivering real-time disk health alerts and recovery notifications through native macOS Notification Center and the Telegram Bot API.

---

## Files

### 1. [`MacOSNotifier.swift`](MacOSNotifier.swift)
Delivers native desktop notifications on macOS:
- **Native Bundle Engine (`UNUserNotificationCenter`)**:
  - `main.swift` automatically resolves symlink invocations (`./disk-health`) into `DiskHealthMonitor.app/Contents/MacOS/DiskHealthMonitor` so the process always runs with its native `CFBundleIdentifier` (`io.github.disk-health-monitor`).
  - Requests `.alert`, `.sound`, and `.badge` authorization and dispatches `UNMutableNotificationContent` notifications with per-drive deduplication identifiers (`disk-health-alert-<driveKey>`) when enabled in `DiskHealthConfig`.
  - Never invokes AppleScript or Script Editor, preventing third-party script popup attribution.

### 2. [`TelegramNotifier.swift`](TelegramNotifier.swift)
Delivers formatted HTML alerts to a Telegram chat or channel via `https://api.telegram.org/bot<token>/sendMessage`:
- **Shared Ephemeral Session**: Uses a dedicated single `URLSession` with 15-second request/resource timeouts to prevent socket and thread leaks across long-running menu bar sessions.
- **HTML Escaping (`escapeHTML`)**: Escapes `&`, `<`, and `>` in all dynamic drive names, mount paths, and issue descriptions so special characters never break Telegram's `parse_mode: "HTML"` parser.
- **Rich Alert Formatting (`sendAlert`)**:
  - Includes severity emoji (`🚨` Critical, `⚠️` Warning, `✅` Healthy/Recovered), drive identity, serial number, connection speed, temperature, free space, SMART status, and detailed issue bullets.
- **Live Verification (`sendTestMessage`)**:
  - Invoked by the **"Send Test Telegram Message"** button in the Settings (`Cmd+,`) window (`Notifications` tab) to verify bot token and chat ID connectivity asynchronously without blocking the UI thread.
