# Universal Disk Health Monitor

[![Build, Test & Release](https://github.com/nikoskoutr/disk-health-monitor/actions/workflows/ci-release.yml/badge.svg)](https://github.com/nikoskoutr/disk-health-monitor/actions/workflows/ci-release.yml)
[![Release](https://img.shields.io/github/v/release/nikoskoutr/disk-health-monitor?color=blue&label=release)](https://github.com/nikoskoutr/disk-health-monitor/releases)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey?logo=apple)](https://apple.com/macos)
[![Architecture](https://img.shields.io/badge/arch-Apple%20Silicon%20%7C%20Intel-orange)](https://github.com/nikoskoutr/disk-health-monitor/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-F05138.svg?logo=swift&logoColor=white)](https://swift.org)

A zero-dependency macOS hardware telemetry daemon, CLI utility, and status bar monitor for internal Apple Silicon/Intel SSDs and external USB, Thunderbolt, and NVMe storage devices.

Built directly on **IOKit**, **DiskArbitration**, **CoreFoundation**, and **Security.framework**, the engine inspects hardware SMART registers, physical bus link speed negotiation, kernel I/O error counters, host thermal pressure, and filesystem writability in real time without requiring `smartmontools` or third-party kernel extensions.

<p align="center">
  <img src="assets/MainWindow.png" alt="Universal Disk Health Monitor Telemetry View" width="380">
</p>

---

## Core Technical Capabilities

- **IOKit Registry Traversal & APFS Physical Store Resolution**: Enumerates mounted volumes via `getfsstat(2)` and `DADiskCreateFromBSDName`, then walks the `kIOServicePlane` parent hierarchy to resolve synthesized APFS containers (`diskXsY` -> `AppleAPFSVolume` -> `AppleAPFSContainer` -> physical `IOMedia`) back to the underlying `IOBlockStorageDriver`, `IONVMeController`, or `IOUSBHostDevice`.
- **128-Bit Native NVMe SMART Telemetry**: Queries `IONVMeSMARTInterface` (Log Page `02h`) and decodes full 16-byte little-endian counters (`Data Units Read`, `Data Units Written`, `Power Cycles`, `Power On Hours`, `Unsafe Shutdowns`, `Media and Data Integrity Errors`, `Available Spare`, `Percentage Used`, and `Composite Temperature`) without 64-bit integer truncation.
- **USB / Thunderbolt Transport & Bridge Diagnostics**: Inspects `IOBlockStorageDriver` statistics (`Statistics` dictionary for read/write ops, bytes transferred, cumulative latency, and I/O errors) and USB device speed negotiation (`Device Speed` / link rate in bps) for external enclosures that lack SAT/NVMe SMART pass-through.
- **Active Canary Filesystem Probe**: Performs periodic non-destructive write, `fsync(2)`, read-back verification, and `unlink(2)` checks on mounted writable volumes to detect silent read-only remounts, hung I/O queues, or controller lockups before metadata corruption occurs.
- **Stateful Alerting & Keychain Credential Storage**: Dispatches transition-aware alerts (`HEALTHY` <-> `WARNING` <-> `CRITICAL`) with configurable per-drive cooldowns via `UNUserNotificationCenter` and the Telegram Bot API. Credentials are stored in the macOS Keychain (`Security.framework`) with an automatic `0600` file fallback for headless SSH/LaunchAgent execution.

---

## System Architecture

```text
disk-health-monitor/
├── build_and_install.sh          # Build, test, packaging, and LaunchAgent installer script
├── .env.example                  # Template environment variable configuration
├── assets/                       # Generated macOS AppIcon.png (1024x1024) and AppIcon.icns
├── scripts/                      # Build-time utilities (CoreGraphics vector AppIcon generator)
├── logs/                         # Runtime logs, latest JSON telemetry snapshot, and state persistence
├── tests/                        # C11/IOKit unit and Swift engine integration test suite
└── src/                          # Modular C11 + Swift 5 source tree
    ├── main.swift                # Entrypoint, CLI argument router, and NSApplication bootstrap
    ├── bridge/                   # Low-level C11 IOKit / DiskArbitration / NVMe SMART bridge
    │   ├── DiskHealthBridge.h    # Public C ABI structs and function declarations
    │   └── DiskHealthBridge.c    # IOKit registry traversal, NVMe SMART client, and statfs calls
    ├── models/                   # Domain models, telemetry snapshots, and POSIX formatters
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
    └── ui/                       # AppKit status bar controller and SwiftUI telemetry/configuration views
        ├── AppDelegate.swift
        ├── DashboardMenuView.swift
        └── SettingsView.swift
```

### Module Documentation Index

| Directory | Documentation | Scope |
| :--- | :--- | :--- |
| [`src/`](src/README.md) | [src/README.md](src/README.md) | C11 + Swift compilation pipeline and inter-module data flow |
| [`src/bridge/`](src/bridge/README.md) | [src/bridge/README.md](src/bridge/README.md) | `kIOServicePlane` traversal, APFS physical store resolution, `IOCFPlugInInterface` NVMe SMART queries |
| [`src/models/`](src/models/README.md) | [src/models/README.md](src/models/README.md) | Telemetry data structures (`DiskHealthSnapshot`), severity levels, and thread-safe formatters |
| [`src/security/`](src/security/README.md) | [src/security/README.md](src/security/README.md) | `Security.framework` Keychain storage and restricted `0600` headless fallback |
| [`src/config/`](src/config/README.md) | [src/config/README.md](src/config/README.md) | Multi-source config resolution, `.env` parser, secret redaction, and structured logging |
| [`src/notifications/`](src/notifications/README.md) | [src/notifications/README.md](src/notifications/README.md) | `UNUserNotificationCenter` dispatcher and Telegram Bot HTTP client |
| [`src/diagnostics/`](src/diagnostics/README.md) | [src/diagnostics/README.md](src/diagnostics/README.md) | Self-contained diagnostic report serializer (`DiagnosticReport`) |
| [`src/engine/`](src/engine/README.md) | [src/engine/README.md](src/engine/README.md) | Health evaluation heuristics, canary I/O probe, delta tracking, and alert cooldown state machine |
| [`src/ui/`](src/ui/README.md) | [src/ui/README.md](src/ui/README.md) | `NSStatusItem` controller and SwiftUI telemetry views |
| [`tests/`](tests/README.md) | [tests/README.md](tests/README.md) | C11/IOKit unit tests, Swift engine unit tests, and CLI integration suite |
| [`scripts/`](scripts/README.md) | [scripts/README.md](scripts/README.md) | CoreGraphics vector icon generator |
| [`logs/`](logs/README.md) | [logs/README.md](logs/README.md) | Runtime log files, latest telemetry JSON, and delta state persistence |
| [`.github/workflows/`](.github/workflows/ci-release.yml) | [ci-release.yml](.github/workflows/ci-release.yml) | GitHub Actions CI test pipeline and multi-architecture release packager |

---

## 12-Point Health Evaluation Engine

Each check cycle collects a `DiskHealthSnapshot` via `DiskHealthBridge.c` and evaluates 12 deterministic rules in `DiskHealthMonitor.swift`:

| # | Rule | Telemetry Source | Trigger Condition | Severity |
| :--- | :--- | :--- | :--- | :--- |
| **1** | **Mount Availability & Subpaths** | `statfs(2)`, `FileManager` | Target volume unmounted or any configured `requiredSubpaths` missing | `CRITICAL` |
| **2** | **Hardware SMART Status** | `IOBlockStorageDevice` / NVMe Critical Warning (`Byte 0`) | Hardware reports SMART failure or NVMe Critical Warning bitmask `!= 0` | `CRITICAL` |
| **3** | **NVMe Available Spare** | NVMe SMART Log `02h` (`Bytes 3–4`) | `availableSpare < availableSpareThreshold` (`CRITICAL`) or `< 20%` (`WARNING`) | `WARNING` / `CRITICAL` |
| **4** | **NVMe Wear (`Percentage Used`)** | NVMe SMART Log `02h` (`Byte 5`) | `percentageUsed >= 90%` (`WARNING`) or `>= 100%` (`CRITICAL`) | `WARNING` / `CRITICAL` |
| **5** | **Drive Composite Temperature** | NVMe SMART Log `02h` (`Bytes 1–2`) | `temperatureCelsius >= tempWarningCelsius` or `>= tempCriticalCelsius` | `WARNING` / `CRITICAL` |
| **6** | **Host Thermal State** | `ProcessInfo.processInfo.thermalState` | Host macOS thermal state in `.critical` (`WARNING`) | `WARNING` |
| **7** | **Media & Kernel I/O Errors** | NVMe Log `02h` (`Bytes 160–175`) & `IOBlockStorageDriver` | Non-zero delta in `mediaErrors`, `Read Errors`, or `Write Errors` since prior snapshot | `WARNING` / `CRITICAL` |
| **8** | **I/O Latency Spikes** | `IOBlockStorageDriver` (`Total Read/Write Time`) | Average read/write operation latency exceeds threshold (`> 50 ms` warn, `> 200 ms` crit) | `WARNING` / `CRITICAL` |
| **9** | **Bus Speed Negotiation** | `IOUSBHostDevice` (`Device Speed`) | USB link negotiates below `minExpectedUsbSpeedBps` (e.g., SuperSpeed drive on USB 2.0 `480 Mbps`) | `WARNING` |
| **10** | **Unsafe Shutdown Delta** | NVMe SMART Log `02h` (`Bytes 144–159`) | `unsafeShutdowns` counter incremented relative to persisted state (`logs/state.json`) | `WARNING` |
| **11** | **Capacity & Free Space** | `statfs(2)` (`f_bavail * f_bsize`) | Usage `%` above warning/critical ceiling OR free GB below warning/critical floor | `WARNING` / `CRITICAL` |
| **12** | **Filesystem Writability & Integrity** | Active Canary Probe & `diskutil verifyVolume` | Read-only mount flags (`MNT_RDONLY`), canary write/fsync/read failure, or `--deep` verification error | `CRITICAL` |

### NVMe Wear & Lifespan Calculation

For NVMe devices, remaining lifespan is computed from **NVMe SMART/Health Information Log Page `02h`, Byte 5 (`Percentage Used`)**:

$$\text{Remaining Lifespan (\%)} = \max(0, 100 - \text{Percentage Used})$$

- Per the NVM Express Base Specification, `Percentage Used` is an integer reported in **1% increments** (values `0` to `255`).
- Controllers frequently round fractional wear (`> 0.0%` of rated TBW) up to `1%`, resulting in `99%` reported remaining lifespan on healthy drives with minor write volume.
- External USB enclosures that block SCSI/ATA Translation (SAT) or NVMe pass-through report `smartSupported = false` (`percentageUsed = -1`) and are evaluated via rules 1, 6, 7, 8, 9, 11, and 12.

---

## Requirements & Build Pipeline

- **OS**: macOS 13.0 (Ventura) or newer (`arm64` Apple Silicon or `x86_64` Intel).
- **Toolchain**: Xcode Command Line Tools (`xcode-select --install`) providing `clang`, `swiftc`, `lipo`, and `iconutil`.

### Build From Source

```bash
./build_and_install.sh
```

Build stages executed by `build_and_install.sh`:
1. Generates `assets/AppIcon.png` and `assets/AppIcon.icns` via `scripts/generate_app_icon.swift` if not cached.
2. Compiles `src/bridge/DiskHealthBridge.c` (`-std=c11 -Wall -Wextra -O2`) into `build/DiskHealthBridge.o`.
3. Compiles all Swift modules under `src/` and links against `DiskHealthBridge.o` and system frameworks (`Cocoa`, `SwiftUI`, `IOKit`, `DiskArbitration`, `Security`, `UserNotifications`) to produce `DiskHealthMonitor.app`.
4. Applies an ad-hoc code signature (`codesign --force --deep --sign -`).
5. Creates a local symlink `./disk-health -> DiskHealthMonitor.app/Contents/MacOS/DiskHealthMonitor`.

### Build, Test & Packaging Targets

```bash
# Execute C11/IOKit unit tests, Swift engine tests, and CLI integration tests
./build_and_install.sh --test

# Cross-compile and package arm64, x86_64, and Universal release artifacts in dist/
./build_and_install.sh --package
# Artifacts produced in dist/:
#   - DiskHealthMonitor-macOS-arm64.dmg & .zip      (Apple Silicon)
#   - DiskHealthMonitor-macOS-x86_64.dmg & .zip    (Intel x86_64)
#   - DiskHealthMonitor-macOS-universal.dmg & .zip (Universal Binary)
#   - disk-health-arm64, disk-health-x86_64, disk-health-universal (Standalone CLI)
#   - SHA256SUMS.txt

# Symlink CLI binary into /usr/local/bin/disk-health
./build_and_install.sh --install-cli

# Install and load background LaunchAgents (periodic check + mount watcher)
./build_and_install.sh --install-service

# Unload and remove background LaunchAgents
./build_and_install.sh --uninstall-service
```

---

## Command-Line Interface (CLI) Reference

```bash
./disk-health [FLAG] [OPTIONS]
```

| Flag | Description |
| :--- | :--- |
| `--status` | Run an immediate health evaluation and print a structured report to `stdout` |
| `--json` | Run a health evaluation and serialize the full `DiskHealthSnapshot` as JSON to `stdout` |
| `--list-disks` | Enumerate all mounted internal and external block devices discovered via IOKit |
| `--check` | Execute a single daemon check cycle (evaluates thresholds, persists state/logs, dispatches alerts) |
| `--watch-mounts` | Execute a mount-triggered evaluation cycle (invoked by `LaunchAgent` `WatchPaths` on `/Volumes`) |
| `--deep` | Append `diskutil verifyVolume` filesystem metadata verification to the check cycle |
| `--volume <path>` | Target a specific mount point (e.g., `--volume /` or `--volume "/Volumes/ExternalSSD"`) |
| `--device <query>` | Target a specific BSD unit, device model, or serial (e.g., `--device disk4`) |
| `--menubar` | Start the persistent `NSStatusItem` background telemetry daemon (default when launched without arguments) |
| `--export-config <path>` | Export the resolved configuration JSON to `<path>` with secrets redacted |
| `--export-diagnostics <path>` | Export a diagnostic JSON bundle (OS build, IOKit disk list, latest snapshot, redacted config, recent logs) |
| `--version`, `-v` | Print version and compiled binary architecture (`arm64` or `x86_64`) |
| `--help`, `-h` | Display CLI usage synopsis |

### Exit Codes

When invoked in CLI check modes (`--status`, `--json`, `--check`, `--watch-mounts`), the process exits with a deterministic status code suitable for cron jobs, monitoring agents, or CI scripts:

- `0`: `HEALTHY` — All evaluated rules passed.
- `1`: `WARNING` — One or more warning thresholds exceeded; no critical failures.
- `2`: `CRITICAL` — Hardware SMART failure, unmounted target, I/O error, or critical threshold breached.

---

## Configuration Schema & Precedence

Configuration parameters are resolved in the following priority order (highest to lowest):

1. **CLI Flags** (`--volume`, `--device`, `--deep`)
2. **Process Environment Variables**
3. **Local `.env` File** (`$DISK_HEALTH_ENV_FILE`, `~/.config/disk-health-monitor/.env`, or `./.env`)
4. **JSON Configuration File** (`~/.config/disk-health-monitor/config.json`)
5. **Compiled Defaults**

### Configuration Reference (`config.json` & Environment Variables)

| JSON Key (`config.json`) | Environment Variable | Type | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `targetVolumePath` | `DISK_HEALTH_VOLUME` | `String` | `""` (Auto) | Explicit mount point to monitor (e.g., `/Volumes/WorkSSD` or `/`). Empty auto-selects the first external volume or `/` |
| `targetDeviceQuery` | `DISK_HEALTH_DEVICE` | `String` | `""` | Match target by BSD disk identifier (`disk4`), model string, or serial number |
| `requiredSubpaths` | `DISK_HEALTH_REQUIRED_SUBPATHS` | `[String]` | `[]` | Relative paths within `targetVolumePath` that must exist when mounted (comma-separated in ENV) |
| `enableActiveCanary` | `ENABLE_ACTIVE_CANARY` | `Bool` | `true` | Write, `fsync()`, read-back, and unlink `.disk_health_canary_probe` on writable volumes |
| `pollIntervalSeconds` | `POLL_INTERVAL_SECONDS` | `Int` | `30` | Background polling interval in seconds (`10`–`3600`) |
| `tempWarningCelsius` | `TEMP_WARNING_CELSIUS` | `Int` | `58` | Drive composite temperature warning threshold (`°C`) |
| `tempCriticalCelsius` | `TEMP_CRITICAL_CELSIUS` | `Int` | `68` | Drive composite temperature critical threshold (`°C`) |
| `diskUsedWarningPercent` | `DISK_USED_WARNING_PERCENT` | `Double` | `85.0` | Volume capacity usage warning threshold (`%`) |
| `diskUsedCriticalPercent` | `DISK_USED_CRITICAL_PERCENT` | `Double` | `93.0` | Volume capacity usage critical threshold (`%`) |
| `minFreeSpaceWarningGB` | `MIN_FREE_SPACE_WARNING_GB` | `Double` | `30.0` | Minimum free space warning floor (`GB`) |
| `minFreeSpaceCriticalGB` | `MIN_FREE_SPACE_CRITICAL_GB` | `Double` | `15.0` | Minimum free space critical floor (`GB`) |
| `minExpectedUsbSpeedBps` | `MIN_EXPECTED_USB_SPEED_BPS` | `UInt64` | `5000000000` | Minimum expected USB link speed in bits/sec (`5000000000` = 5 Gbps USB 3.0) |
| `enableNativeNotifications` | `ENABLE_NATIVE_NOTIFICATIONS` | `Bool` | `true` | Dispatch alerts via macOS `UNUserNotificationCenter` |
| `telegramBotToken` | `TELEGRAM_BOT_TOKEN` | `String` | `""` | Telegram Bot API token (persisted in macOS Keychain, redacted in `config.json`) |
| `telegramChatId` | `TELEGRAM_CHAT_ID` | `String` | `""` | Target Telegram chat or channel ID for HTML alert payloads |
| `alertCooldownSeconds` | `ALERT_COOLDOWN_SECONDS` | `Int` | `3600` | Minimum suppression window (seconds) before repeating an identical alert for the same volume |

### Example `~/.config/disk-health-monitor/config.json`

```json
{
  "alertCooldownSeconds": 3600,
  "diskUsedCriticalPercent": 93,
  "diskUsedWarningPercent": 85,
  "enableActiveCanary": true,
  "enableNativeNotifications": true,
  "minExpectedUsbSpeedBps": 5000000000,
  "minFreeSpaceCriticalGB": 15,
  "minFreeSpaceWarningGB": 30,
  "pollIntervalSeconds": 30,
  "requiredSubpaths": [],
  "targetDeviceQuery": "",
  "targetVolumePath": "/Volumes/ExternalNVMe",
  "telegramBotToken": "REDACTED_IN_KEYCHAIN",
  "telegramChatId": "-1001234567890",
  "tempCriticalCelsius": 68,
  "tempWarningCelsius": 58
}
```

---

## Credential Security & Headless Operation

- **macOS Keychain Integration**: When `telegramBotToken` is configured, `SecretStore.swift` stores the secret in the login Keychain via `SecItemAdd` / `SecItemUpdate` (`kSecClassGenericPassword`, service `io.github.disk-health-monitor`, account `telegramBotToken`). The on-disk `config.json` (`0600` permissions) stores only the sentinel `"REDACTED_IN_KEYCHAIN"`.
- **Headless / SSH Fallback**: If the macOS Keychain is locked or inaccessible (e.g., an unauthenticated SSH session or root cron context returning `errSecInteractionNotAllowed`), `SecretStore` falls back to `~/.config/disk-health-monitor/.secrets.json` enforced with POSIX `0600` permissions, or reads `TELEGRAM_BOT_TOKEN` directly from the environment / `.env` file:

```bash
cp .env.example ~/.config/disk-health-monitor/.env
chmod 600 ~/.config/disk-health-monitor/.env
```

```dotenv
TELEGRAM_BOT_TOKEN=123456789:AAExampleBotTokenValue
TELEGRAM_CHAT_ID=-1001234567890
```

---

## License

Released under the [MIT License](LICENSE).
