# Menu Bar Controller & SwiftUI Views (`src/ui/`)

This directory contains the native macOS user interface layer built with AppKit (`NSStatusItem`, `NSMenu`, `NSWindow`) and SwiftUI (`DashboardMenuView`, `SettingsView`).

---

## Files

### 1. [`AppDelegate.swift`](AppDelegate.swift)
Manages the application lifecycle, menu bar status item, background refresh timer, and Settings window:
- **Menu Bar Status Item (`NSStatusBar`)**:
  - Dynamically updates the menu bar SF Symbol icon based on the latest health state (`externaldrive.badge.checkmark` for healthy, `externaldrive.trianglebadge.exclamationmark` for warning/critical, or `externaldrive.badge.questionmark` when unmounted).
- **Embedded SwiftUI Dashboard (`NSHostingView`)**:
  - Hosts `DashboardMenuView` (360×510 pt) at the top of the status bar menu alongside native `NSMenuItem` shortcuts:
    - **Run Quick Check Now** (`Cmd+R`)
    - **Run Deep Check (`verifyVolume`)** (`Cmd+D`)
    - **Switch Monitored Drive** (dynamically populated from `DiskListMountedDisks()`)
    - **Settings (`Cmd+,`)...**
    - **Export Diagnostic Report...** (`Cmd+E`)
    - **Open Drive in Finder** (`Cmd+O`)
    - **View Health Log** (`Cmd+L`)
- **Standard Edit Menu (`setupMainMenu`)**:
  - Installs a standard macOS `Edit` menu (`Undo`, `Redo`, `Cut`, `Copy`, `Paste`, `Select All`) so keyboard shortcuts (`Cmd+C`, `Cmd+V`, `Cmd+A`) work natively inside the Settings window's text and password fields.
- **Observer Registration**:
  - Listens for `.diskHealthConfigDidChange` notifications from `SettingsView` to immediately reload configuration and re-run a health check when the user saves settings.

### 2. [`DashboardMenuView.swift`](DashboardMenuView.swift)
Renders the visual telemetry popover card inside the menu bar dropdown:
- **Header Banner**: Displays drive product name, BSD unit (`diskX`), transport speed, and a color-coded `HEALTHY` / `WARNING` / `CRITICAL` badge.
- **2×2 Telemetry Grid**:
  - **Storage Capacity**: Free vs. total space with a color-coded usage progress bar.
  - **Temperature**: Current drive temperature in `°C` with a thermal progress bar scaled against `tempCriticalCelsius`.
  - **SSD Lifespan**: Remaining lifespan percentage (`100 - percentageUsed`) and available spare percentage (`availableSparePercent`).
  - **Power & Health**: SMART status badge, power-on hours (`POH`), power cycles, and unsafe shutdown count.
- **Session I/O & Lifetime Totals**:
  - Displays cumulative session read/write throughput, average canary latency (`ms`), kernel I/O error count, and lifetime NVMe Terabytes Read/Written (`TBR` / `TBW`).
- **Active Issues Banner & Quick Action Footer**:
  - Highlights up to two active anomalies and provides one-click **Refresh**, **Diagnostics**, and **Settings** buttons.

### 3. [`SettingsView.swift`](SettingsView.swift)
Implements the 4-tab macOS Preferences window (`Cmd+,`, 580×490 pt):
- **General Tab**:
  - Interactive drive picker listing all mounted disks plus custom volume/device fields and a **Config File** export button.
- **Thresholds Tab**:
  - Interactive sliders and steppers for Warning/Critical temperatures (`°C`), Warning/Critical free disk space (`%`), Canary Write Latency Warning (`ms`), and Alert Cooldown (`minutes`), with live validation (`Warning < Critical`) and a **Reset to Defaults** button.
- **Notifications Tab**:
  - Toggles native macOS Notification Center alerts, provides a `SecureField` (with show/hide toggle) for the Keychain-backed Telegram Bot Token, a Chat ID field, and a live **"Send Test Telegram Message"** button.
- **Diagnostics Tab**:
  - Displays config and log file paths with **Reveal in Finder** buttons and one-click exporters for sanitized config JSON and full diagnostic bundles.
