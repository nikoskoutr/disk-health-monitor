# Universal Disk Health Monitor

A native, zero-dependency macOS hardware telemetry daemon, menu bar application, and CLI tool for monitoring internal Apple Silicon/Intel SSDs and external USB/Thunderbolt/NVMe storage drives.

Built directly on top of **IOKit**, **DiskArbitration**, **CoreFoundation**, and **SwiftUI/AppKit**, Universal Disk Health Monitor inspects hardware SMART registers, bus negotiation speeds, I/O error counters, thermal states, and filesystem writability in real time—without requiring `smartmontools` or third-party kernel extensions.

<p align="center">
  <img src="assets/MainWindow.png" alt="Universal Disk Health Monitor Menu Bar Dashboard" width="380">
</p>

---

## Key Capabilities

- **Universal Drive Discovery & APFS Container Resolution**: Automatically enumerates all mounted internal and external volumes or targets a specific mount point/BSD unit (`diskX`). Traverses the `IOService` parent plane to resolve synthesized APFS containers (`diskXsY`) back to their underlying physical NVMe or USB storage controller.
- **128-Bit Native NVMe SMART Telemetry**: Reads full 16-byte little-endian NVMe SMART health log counters (`Data Units Read`, `Data Units Written`, `Power Cycles`, `Power On Hours`, `Unsafe Shutdowns`, `Media Errors`, `Available Spare`, `Percentage Used`, and `Composite Temperature`) without 64-bit truncation.
- **12-Point Automated Health Evaluation Engine**: Evaluates SMART status, NVMe spare capacity, wear level (`Percentage Used`), drive temperature, host macOS thermal pressure, kernel I/O errors, read/write latency spikes, bus speed negotiation anomalies, unsafe shutdown deltas, free disk space, canary file writability, and optional `diskutil verifyVolume` checks.
- **Native Menu Bar App & Preferences Window (`Cmd+,`)**:
  - Live menu bar status icon with instant drive switcher.
  - Rich graphical dashboard displaying health badges, thermal and SSD wear gauges, lifetime TBW/TBR counters, and cumulative session I/O throughput.
  - Multi-tab **Settings Window (`Cmd+,`)** across **General**, **Thresholds**, **Notifications**, and **Diagnostics**.
- **Dual-Channel Alerting with Cooldowns**: Dispatches stateful alerts via native macOS Notification Center (`UNUserNotificationCenter`) and optional Telegram Bot HTML messages with configurable per-drive alert cooldowns.
- **macOS Keychain Credential Protection**: Stores sensitive tokens (`telegramBotToken`) in the native macOS Keychain (`Security.framework`) with automatic `0600` file fallback for headless SSH/LaunchAgent environments.

---

## Repository Architecture

Every directory in this repository includes its own `README.md` documenting its internal design, data flow, and files:

```text
disk-health-monitor/
├── build_and_install.sh          # Universal build, test, and LaunchAgent installer script
├── .env.example                  # Template environment variable configuration
├── assets/                       # Generated macOS AppIcon.png (1024x1024) and AppIcon.icns
├── scripts/                      # Build-time utilities (CoreGraphics vector AppIcon generator)
├── logs/                         # Runtime logs, latest JSON telemetry snapshot, and state persistence
├── tests/                        # C/IOKit unit and hardware integration test suite
└── src/                          # Modular C11 + Swift 5 source code
    ├── main.swift                # Entrypoint, CLI argument router, and NSApplication bootstrap
    ├── bridge/                   # Low-level C11 IOKit / DiskArbitration / NVMe SMART bridge
    │   ├── DiskHealthBridge.h    # Public C ABI structs and function declarations
    │   └── DiskHealthBridge.c    # IOKit registry traversal, NVMe SMART client, and statfs calls
    ├── models/                   # Core domain models, telemetry snapshots, and POSIX formatters
    │   └── HealthModels.swift
    ├── security/                 # macOS Keychain (Security.framework) & 0600 fallback secret store
    │   └── SecretStore.swift
    ├── config/                   # Configuration hierarchy (.env, config.json, CLI) & logger
    │   └── ConfigManager.swift
    ├── notifications/            # Alert dispatchers for macOS Notification Center and Telegram
    │   ├── MacOSNotifier.swift
    │   └── TelegramNotifier.swift
    ├── diagnostics/              # Sanitized JSON diagnostic bundle generator
    │   └── DiagnosticExporter.swift
    ├── engine/                   # 12-rule health evaluation engine, canary probe, and state tracker
    │   └── DiskHealthMonitor.swift
    └── ui/                       # AppKit status bar controller and SwiftUI dashboard/settings views
        ├── AppDelegate.swift
        ├── DashboardMenuView.swift
        └── SettingsView.swift
```

### Subfolder Documentation Index

| Directory | Documentation Link | Purpose |
| :--- | :--- | :--- |
| [`src/`](src/README.md) | [src/README.md](src/README.md) | Architectural overview of the C + Swift compilation pipeline and module interactions |
| [`src/bridge/`](src/bridge/README.md) | [src/bridge/README.md](src/bridge/README.md) | IOKit registry traversal, APFS physical store resolution, NVMe SMART plugin querying |
| [`src/models/`](src/models/README.md) | [src/models/README.md](src/models/README.md) | Telemetry data structures (`DiskHealthSnapshot`), severity levels, and thread-safe formatters |
| [`src/security/`](src/security/README.md) | [src/security/README.md](src/security/README.md) | `Security.framework` Keychain storage and restricted `0600` headless fallback |
| [`src/config/`](src/config/README.md) | [src/config/README.md](src/config/README.md) | Multi-source config resolution, `.env` parsing, secret redaction, and logging |
| [`src/notifications/`](src/notifications/README.md) | [src/notifications/README.md](src/notifications/README.md) | Native macOS notifications (`UNUserNotificationCenter`) and Telegram Bot API client |
| [`src/diagnostics/`](src/diagnostics/README.md) | [src/diagnostics/README.md](src/diagnostics/README.md) | Self-contained diagnostic report exporter (`DiagnosticReport`) |
| [`src/engine/`](src/engine/README.md) | [src/engine/README.md](src/engine/README.md) | Core health check orchestration, 12 evaluation rules, canary write probe, and alert cooldowns |
| [`src/ui/`](src/ui/README.md) | [src/ui/README.md](src/ui/README.md) | Menu bar controller, popover telemetry card, and 4-tab `Cmd+,` Settings window |
| [`tests/`](tests/README.md) | [tests/README.md](tests/README.md) | C/IOKit unit, Swift core engine unit, and CLI integration test suite |
| [`scripts/`](scripts/README.md) | [scripts/README.md](scripts/README.md) | CoreGraphics vector icon generator script |
| [`assets/`](assets/README.md) | [assets/README.md](assets/README.md) | Generated application icons (`AppIcon.png`, `AppIcon.icns`) and UI screenshots |
| [`logs/`](logs/README.md) | [logs/README.md](logs/README.md) | Runtime log files, latest telemetry JSON, and delta state persistence |
| [`.github/workflows/`](.github/workflows/ci-release.yml) | [ci-release.yml](.github/workflows/ci-release.yml) | GitHub Actions CI test pipeline and automated Universal macOS Release packager |

---

## Requirements & Building

- **Operating System**: macOS 13.0 (Ventura) or later (Apple Silicon or Intel).
- **Toolchain**: Xcode Command Line Tools (`xcode-select --install`) providing `clang`, `swiftc`, and `iconutil`.

### Build the Application Bundle

```bash
./build_and_install.sh
```

What `./build_and_install.sh` does:
1. Generates `assets/AppIcon.png` and `assets/AppIcon.icns` via `scripts/generate_app_icon.swift` if not already cached.
2. Compiles `src/bridge/DiskHealthBridge.c` into a C11 object file (`build/DiskHealthBridge.o`).
3. Compiles all Swift modules under `src/` and links them with `DiskHealthBridge.o` and macOS system frameworks (`Cocoa`, `SwiftUI`, `IOKit`, `DiskArbitration`, `Security`, `UserNotifications`) into `DiskHealthMonitor.app`.
4. Ad-hoc codesigns `DiskHealthMonitor.app`.
5. Creates a local convenience symlink `./disk-health -> DiskHealthMonitor.app/Contents/MacOS/DiskHealthMonitor` (git-ignored) so you can run CLI commands directly from the project root.

### Optional Build, Test & Packaging Flags

```bash
# Run the C/IOKit, Swift core engine, and CLI integration test suite
./build_and_install.sh --test

# Build and package architecture-specific (arm64, x86_64) and Universal assets into dist/
./build_and_install.sh --package
# Produces in dist/:
#   - DiskHealthMonitor-macOS-arm64.dmg & .zip      (Apple Silicon M1/M2/M3/M4)
#   - DiskHealthMonitor-macOS-x86_64.dmg & .zip    (Intel 64-bit / x64)
#   - DiskHealthMonitor-macOS-universal.dmg & .zip (Universal Binary)
#   - disk-health-arm64, disk-health-x86_64, disk-health-universal (Standalone CLI)
#   - SHA256SUMS.txt (Cryptographic verification checksums)

# Symlink the CLI binary to /usr/local/bin/disk-health
./build_and_install.sh --install-cli

# Install and start background LaunchAgents
./build_and_install.sh --install-service

# Stop and remove background LaunchAgents
./build_and_install.sh --uninstall-service
```

---

## Usage Guide

### 1. Menu Bar Application (Default)

Launch the app bundle or run the binary without arguments:

```bash
open DiskHealthMonitor.app
# or
./disk-health --menubar
```

- Click the menu bar icon to inspect real-time health, temperature, SSD wear, bus speed, and session I/O counters.
- Switch between mounted drives using the **Switch Monitored Drive** submenu.
- Press **`Cmd+,`** (or click **Settings (`Cmd+,`)...**) to configure target drives, alert thresholds, native/Telegram notifications, and diagnostic exports.

### 2. Command-Line Interface (CLI)

| Flag | Description |
| :--- | :--- |
| `--status` | Run an immediate health check and print a formatted report to `stdout` |
| `--json` | Run a health check and output the raw `DiskHealthSnapshot` as pretty-printed JSON |
| `--list-disks` | List all currently mounted internal and external disks detected via IOKit |
| `--check` | Run a single background check cycle (evaluates thresholds, updates `logs/`, sends alerts) |
| `--watch-mounts` | Run a check triggered by a DiskArbitration/LaunchAgent mount event |
| `--deep` | Include `diskutil verifyVolume` filesystem structure verification during the check |
| `--volume <path>` | Override the target mount path (e.g. `--volume "/Volumes/ExternalSSD"` or `--volume /`) |
| `--device <query>` | Override the target BSD device or model name (e.g. `--device disk4`) |
| `--export-config <path>` | Export the active configuration to `<path>` with secrets automatically redacted |
| `--export-diagnostics <path>` | Export a comprehensive JSON diagnostic bundle (OS info, disk list, snapshot, redacted config, recent logs) |
| `--version`, `-v` | Display application version and target binary architecture (`arm64` or `x86_64`) |
| `--help`, `-h` | Show CLI usage instructions |

---

## How SSD Lifespan & Wear Are Calculated

For NVMe drives, SSD lifespan is derived directly from the hardware controller's **NVMe SMART/Health Information Log (Log Page `02h`, Byte 5: `Percentage Used`)**:

$$\text{Remaining Lifespan (\%)} = \max(0, 100 - \text{Percentage Used})$$

- Per the NVMe specification, `Percentage Used` is an integer reported by the controller firmware in **1% increments**.
- As soon as a new drive accumulates any measurable wear above `0.0%` (for example, `0.2%` or `0.5%` of its rated Terabytes Written), many NVMe controllers (including Apple Silicon internal SSDs) round up and report `Percentage Used = 1%`, which displays as **99% Lifespan (`1% used`)**.
- USB-bridged external drives that block SAT/NVMe SMART pass-through over USB Mass Storage (`smartSupported == false`) report `percentageUsed = -1` (`N/A`) and rely on active canary I/O probes, kernel I/O error counters, latency tracking, and bus negotiation checks instead.

---

## Settings Window (`Cmd+,`) & Configuration Guide

Press **`Cmd+,`** while the menu bar app is open (or select **Settings (`Cmd+,`)...** from the status bar menu) to open the 4-tab native macOS Preferences window:

### 1. General Tab (`Target Drive & Service`)
- **Monitored Disk / Volume**: Choose **Auto-Detect First External Drive** (default) or select any specific hardware block device (`diskX`) or mounted volume (`/Volumes/...`, `/`) from the live dropdown.
- **Target Volume Mount Path (`targetVolumePath`)**: Optional explicit mount point override (e.g., `/Volumes/MediaSSD`).
- **Target Device Query (`targetDeviceQuery`)**: Optional BSD device name (`disk4`), drive product model (`External SSD`), or hardware serial number.
- **Required Subpaths (`requiredSubpaths`)**: Optional comma-separated list of relative paths inside the volume that must exist and remain accessible whenever the volume is mounted.
- **Enable Active Canary Write/Read Probe (`enableActiveCanary`)**: Toggles the periodic `.disk_health_canary_probe` write, `fsync()`, read-back, and unlink test on writable volumes (default: `true`).
- **Background Polling Interval (`pollIntervalSeconds`)**: Controls how frequently the menu bar daemon evaluates drive health (`10s`, `30s`, `60s`, `5m`, or `15m`; default: `30s`).
- **Launch at Login (`LaunchAgent`)**: One-click toggle that installs or removes `~/Library/LaunchAgents/io.github.disk-health-monitor.plist` via `launchctl`.

### 2. Thresholds Tab (`Thermal, Capacity & Bus Rules`)
All sliders enforce automatic safety bounds (e.g., `Warning < Critical`) and update live:
- **Temperature Warning (`tempWarningCelsius`)**: Triggers a `WARNING` alert when drive temperature reaches this threshold (default: `58°C`, range: `35°C–80°C`).
- **Temperature Critical (`tempCriticalCelsius`)**: Triggers a `CRITICAL` alert when drive temperature reaches this threshold (default: `68°C`, range: `45°C–95°C`).
- **Disk Used Warning (`diskUsedWarningPercent`)**: Triggers a `WARNING` when volume usage exceeds this percentage (default: `85%`).
- **Disk Used Critical (`diskUsedCriticalPercent`)**: Triggers a `CRITICAL` alert when volume usage exceeds this percentage (default: `93%`).
- **Minimum Free Space Warning (`minFreeSpaceWarningGB`)**: Triggers a `WARNING` when free capacity drops below this floor (default: `30 GB`).
- **Minimum Free Space Critical (`minFreeSpaceCriticalGB`)**: Triggers a `CRITICAL` alert when free capacity drops below this floor (default: `15 GB`).
- **Minimum Expected USB Bus Speed (`minExpectedUsbSpeedBps`)**: Alerts if an external USB drive negotiates below expected link speed (`480 Mbps` USB 2.0, `5 Gbps` USB 3.0 SuperSpeed, or `10 Gbps` USB 3.2 Gen 2; default: `5 Gbps`).
- **Reset to Recommended Defaults**: Restores all threshold settings to their factory defaults.

### 3. Notifications Tab (`macOS & Telegram Alerts`)
- **Enable Native macOS Notifications (`enableNativeNotifications`)**: Toggles native macOS Notification Center alerts (`UNUserNotificationCenter`) with sound and banner support (default: `true`).
- **Telegram Bot Token & Chat ID**: Configures instant remote mobile/desktop push alerts via the Telegram Bot API.
- **Alert Cooldown Period (`alertCooldownSeconds`)**: Minimum quiet window before re-sending an alert for the same ongoing issue (`5m`, `15m`, `30m`, `1h`, `6h`, or `24h`; default: `1 hour / 3600s`).
- **Send Test Message**: Immediately dispatches a live test notification to both macOS Notification Center and your configured Telegram chat, reporting success or any API error inline.

### 4. Diagnostics Tab (`Config & Telemetry Export`)
- **Configuration & Logs Directories**: Shows the active paths (`~/.config/disk-health-monitor` and `logs/`) with one-click **Reveal in Finder** buttons.
- **Export / Import Configuration JSON**: Saves a sanitized copy of your configuration (with secrets masked as `•••••••• (Protected)`) or imports a previously saved `.json` profile.
- **Export Full Diagnostic Bundle**: Writes a comprehensive JSON report containing macOS version info, all discovered IOKit storage devices, the latest `DiskHealthSnapshot`, sanitized configuration, and recent `health.log` lines.

---

## How to Configure Telegram Notifications

You can receive rich HTML alerts (for `WARNING`, `CRITICAL`, and `✅ HEALTHY` recovery transitions) by providing your **Telegram Bot Token** and **Chat ID** using any of the three methods below:

### Option A: Via the Menu Bar Settings UI (`Cmd+,`) — *Recommended*
1. Launch `DiskHealthMonitor.app` and press **`Cmd+,`** to open **Settings**.
2. Switch to the **Notifications** tab.
3. Paste your **Bot Token** into the **Bot Token** field (click the eye icon to verify it) and enter your **Chat ID**.
4. Your Bot Token is automatically saved to the **macOS Keychain** (`Security.framework`, service `io.github.disk-health-monitor`) and written as `"REDACTED_IN_KEYCHAIN"` inside `~/.config/disk-health-monitor/config.json` (`0600` permissions).
5. Click **Send Test Message** to verify delivery.

### Option B: Via a `.env` File
Copy `.env.example` to `.env` in the project root (or `~/.config/disk-health-monitor/.env`) and restrict its permissions:
```bash
cp .env.example .env
chmod 600 .env
```
Edit `.env`:
```dotenv
TELEGRAM_BOT_TOKEN=your_telegram_bot_token_here
TELEGRAM_CHAT_ID=your_telegram_chat_id_here
```

### Option C: Via Environment Variables
Pass the credentials directly when invoking the CLI or service:
```bash
TELEGRAM_BOT_TOKEN="your_telegram_bot_token_here" TELEGRAM_CHAT_ID="your_telegram_chat_id_here" ./disk-health --check
```

---

## Configuration Precedence & Security

Configuration settings are merged in the following priority order (highest to lowest):
1. **CLI Arguments** (`--volume`, `--device`, `--deep`)
2. **Process Environment Variables** (`DISK_HEALTH_VOLUME`, `DISK_HEALTH_DEVICE`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`, `TEMP_WARNING_CELSIUS`, `TEMP_CRITICAL_CELSIUS`, `DISK_USED_WARNING_PERCENT`, `DISK_USED_CRITICAL_PERCENT`, `MIN_FREE_SPACE_WARNING_GB`, `MIN_FREE_SPACE_CRITICAL_GB`)
3. **Local `.env` File** (`$DISK_HEALTH_ENV_FILE`, `~/.config/disk-health-monitor/.env`, or `./.env`)
4. **JSON Configuration File** (`~/.config/disk-health-monitor/config.json`, edited via `Cmd+,` Settings)
5. **Built-In Defaults**

Sensitive credentials (`telegramBotToken`) are stripped from `config.json` before writing to disk (`0600` permissions) and stored securely in the macOS Keychain under service `io.github.disk-health-monitor` (with a `0600` `~/.config/disk-health-monitor/.secrets.json` fallback for headless SSH environments).

---

## License

Released under the [MIT License](LICENSE).

