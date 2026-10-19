# Notification Dispatchers (`src/notifications/`)

This directory contains the notification dispatchers responsible for delivering real-time disk health alerts and recovery notifications through native macOS Notification Center and the Telegram Bot API.

---

## Files

### 1. [`MacOSNotifier.swift`](MacOSNotifier.swift)
Delivers native desktop notifications on macOS:
- **Primary Engine (`UNUserNotificationCenter`)**:
  - Checks whether the process is executing inside a valid `.app` bundle (`Bundle.main.bundleIdentifier != nil`).
  - Requests `.alert` and `.sound` authorization and dispatches `UNMutableNotificationContent` notifications when enabled in `MonitorConfig`.
- **Headless CLI Fallback (`osascript`)**:
  - When invoked from a raw CLI context or background script where `UNUserNotificationCenter` is unavailable, safely falls back to `/usr/bin/osascript -e 'display notification ...'` with escaped string literals.

### 2. [`TelegramNotifier.swift`](TelegramNotifier.swift)
Delivers formatted HTML alerts to a Telegram chat or channel via `https://api.telegram.org/bot<token>/sendMessage`:
- **Shared Ephemeral Session**: Uses a dedicated single `URLSession` with 15-second request/resource timeouts to prevent socket and thread leaks across long-running menu bar sessions.
- **HTML Escaping (`escapeHTML`)**: Escapes `&`, `<`, and `>` in all dynamic drive names, mount paths, and issue descriptions so special characters never break Telegram's `parse_mode: "HTML"` parser.
- **Rich Alert Formatting (`sendAlert`)**:
  - Includes severity emoji (`🚨` Critical, `⚠️` Warning, `✅` Healthy/Recovered), drive identity, serial number, connection speed, temperature, free space, SMART status, and detailed issue bullets.
- **Live Verification (`sendTestMessage`)**:
  - Invoked by the **"Send Test Telegram Message"** button in the Settings (`Cmd+,`) window (`Notifications` tab) to verify bot token and chat ID connectivity asynchronously without blocking the UI thread.
