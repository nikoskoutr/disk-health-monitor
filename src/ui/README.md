# Menu Bar Controller & User Interface (`src/ui/`)

This directory implements the native macOS user interface using AppKit (`NSStatusItem`, `NSMenu`, `NSWindow`) and SwiftUI (`DashboardMenuView`, `SettingsView`).

---

## Files

### 1. [`AppDelegate.swift`](AppDelegate.swift)
Coordinates the application lifecycle, menu bar status item, and system observers:
- **Status Item**: Updates the menu bar SF Symbol dynamically based on health state (`externaldrive.fill.badge.checkmark` for healthy, `externaldrive.trianglebadge.exclamationmark` for warning, `externaldrive.fill.badge.xmark` for critical).
- **Embedded Dashboard**: Embeds `DashboardMenuView` (385 pt) at the top of the menu bar dropdown alongside quick actions:
  - **Hardware S.M.A.R.T. Inspector** (`⌘I`)
  - **Run Deep Health & Canary Check Now** (`⌘R`)
  - **Generate Standalone HTML Report...** (`⌘H`)
  - **Verify Volume File System (`diskutil`)...** (`⌘V`)
  - **Export Diagnostic Report (JSON)...** (`⌘E`)
  - **Send Status Report to Telegram Now** (`⌘T`)
  - **Settings...** (`⌘,`)
  - **Select Monitored Disk** (dynamically populated from `DiskListAllDevices`)
- **System Observers**: Listens for sleep/wake events, filtered volume mount notifications (ignoring system recovery/snapshot mounts), and dynamic polling timer updates.
- **Standard Edit Menu**: Installs native Edit menu shortcuts (`⌘C`, `⌘V`, `⌘A`) for all text fields inside the Settings window.

---

### 2. [`DashboardMenuView.swift`](DashboardMenuView.swift)
Renders the visual telemetry popover card in the status bar menu:
- **Header**: Drive product name, BSD identifier (`diskX`), transport speed, and health severity badge.
- **Telemetry Grid**:
  - **Capacity**: Free vs. total space, nominal usage bar, and APFS purgeable space accounting.
  - **Thermal**: Current drive temperature with a color-coded gauge scaled against `tempCriticalCelsius`.
  - **SSD Wear & Lifespan**: Remaining lifespan percentage (`100 - percentageUsed`) and available spare health.
  - **Power & Health**: S.M.A.R.T. readiness, Power-On Hours (POH), power cycles, and unsafe shutdowns.
- **Live I/O & Canary**: Active read/write throughput ($\text{MB/s}$), cumulative lifetime TBW, canary latency ($\text{ms}$), and driver error tallies.
- **Issues Banner**: Real-time listing of active health anomalies with severity badges.

---

### 3. [`SettingsView.swift`](SettingsView.swift), [`SettingsViewModel.swift`](SettingsViewModel.swift) & [`tabs/`](tabs/)
Implements the 6-tab native macOS Preferences window (`⌘,`, 720×660 pt):

1. **General Tab ([`GeneralSettingsTab.swift`](tabs/GeneralSettingsTab.swift))**:
   - Monitor All Connected Disks toggle, single-drive selector, and multi-disk target checklist.
   - LaunchAgent background service toggle with clean `launchctl` state synchronization.
   - Polling frequency slider (`10s` to `300s`), active canary toggle, and scheduled verification interval.
2. **Thresholds Tab ([`ThresholdsSettingsTab.swift`](tabs/ThresholdsSettingsTab.swift))**:
   - Temperature warning/critical thresholds (°C).
   - Capacity usage ceiling (%) and minimum free space floors (GB).
   - Minimum expected USB bus speed selector and alert cooldown duration.
3. **Notifications Tab ([`NotificationsSettingsTab.swift`](tabs/NotificationsSettingsTab.swift))**:
   - Native Notification Center toggle and audible critical audio beeps.
   - Opt-in macOS Keychain storage onboarding and status indicator.
   - Telegram Bot API configuration with `SecureField` token entry and live test message dispatcher.
   - Universal Webhook URL (Discord, Slack, Mattermost, Home Assistant) with live test button.
   - Custom alert shell script hook path with validation runner.
4. **S.M.A.R.T. Tab ([`SmartInspectorTab.swift`](tabs/SmartInspectorTab.swift), `⌘I`)**:
   - Dedicated hardware inspector displaying all raw NVMe registers, normalized attributes, composite temperatures, critical warning bits, daily write burn rate ($\text{TB/day}$), and projected remaining lifespan.
5. **Statistics & Insights Tab ([`StatisticsTab.swift`](tabs/StatisticsTab.swift))**:
   - Multi-disk fleet comparison cards, endurance projections, I/O latency & throughput metrics, and capacity breakdown across all monitored drives.
6. **Diagnostics Tab ([`DiagnosticsAndExportTab.swift`](tabs/DiagnosticsAndExportTab.swift))**:
   - **Multi-Tier Surface Scan**: Selectable modes (`quick`, `standard`, `full`) with live progress, file counts, throughput ($\text{MB/s}$), and cancel support.
   - **Volume Verification**: Manual `diskutil verifyVolume` execution and baseline reset actions.
   - **Profiles & Reports**: One-click actions to Export HTML Report (`⌘H`), Export Diagnostic JSON, Export Sanitized Config, and Import Config Profile.
