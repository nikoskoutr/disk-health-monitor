# Menu Bar Controller & User Interface (`src/ui/`)

This directory implements the native macOS user interface using AppKit (`NSStatusItem`, `NSMenu`, `NSWindow`) and SwiftUI (`DashboardMenuView`, `SettingsView`).

---

## Files

### 1. [`AppDelegate.swift`](AppDelegate.swift)
Coordinates the application lifecycle, menu bar status item, and system observers:
- **Status Item**: Updates the menu bar SF Symbol dynamically based on health state (`externaldrive.fill.badge.checkmark` for healthy, `externaldrive.trianglebadge.exclamationmark` for warning, `externaldrive.fill.badge.xmark` for critical) and formats title via `AppDelegate.formatStatusBarTitle(for:)`. Unifies disk cache refresh and health evaluation sequentially in `menuWillOpen` to eliminate concurrent IOKit SMART contention.
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

### 3. [`SettingsView.swift`](SettingsView.swift), [`SettingsViewModel.swift`](SettingsViewModel.swift), [`SettingsComponents.swift`](SettingsComponents.swift) & [`tabs/`](tabs/)
Implements the 7-tab native macOS Preferences window (`⌘,`, 820×700 pt) with shared UI components (`SmartAttributeRow`, `SmartAttributesTableView`) and offloaded background actions:

1. **General Tab ([`GeneralSettingsTab.swift`](tabs/GeneralSettingsTab.swift))**:
   - Monitor All Connected Disks toggle, single-drive selector, multi-disk target checklist, and Pre-Sleep External Drive Shield toggle.
   - LaunchAgent background service toggle synchronized via `SubprocessRunner` (`launchctl`).
   - Polling frequency slider (`10s` to `300s`), active canary toggle, and scheduled verification interval.
2. **Thresholds Tab ([`ThresholdsSettingsTab.swift`](tabs/ThresholdsSettingsTab.swift))**:
   - Temperature warning/critical thresholds (°C).
   - Capacity usage ceiling (%) and minimum free space floors (GB).
   - Minimum expected USB bus speed selector and alert cooldown duration.
3. **Notifications Tab ([`NotificationsSettingsTab.swift`](tabs/NotificationsSettingsTab.swift))**:
   - Native Notification Center toggle, audible critical beeps, and Prometheus/OpenMetrics loopback server toggle + port (`9102`).
   - Opt-in macOS Keychain storage onboarding and status indicator.
   - Telegram Bot API configuration (`SecureField`), Universal Webhook URL, and custom alert script hook.
4. **S.M.A.R.T. Tab ([`SmartInspectorTab.swift`](tabs/SmartInspectorTab.swift), `⌘I`)**:
   - Dedicated hardware inspector rendering shared `SmartAttributesTableView` / `SmartAttributeRow`, HID die thermal status, kernel I/O driver stats, PHY CRC/reset counters, and bad physical LBA extents.
5. **Statistics & Insights Tab ([`StatisticsAndInsightsTab.swift`](tabs/StatisticsAndInsightsTab.swift), `⌘S`)**:
   - Multi-disk fleet cards, 7d/30d OLS wear projections, SwiftUI trend sparklines, runaway I/O process throttler, and context-aware APFS snapshot inventory (`apfsSnapshotsMount`).
6. **Diagnostics Tab ([`DiagnosticsAndExportTab.swift`](tabs/DiagnosticsAndExportTab.swift))**:
   - **Multi-Tier Surface Scan**: `quick`, `standard`, `full` modes with live progress and cancellation.
   - **Open File Blockers & Volume Verification**: Interactive blocker inspection with fail-closed `isTerminatable` termination, unmount controls, and `diskutil verifyVolume`.
   - **Profiles & Reports**: Export HTML RMA Report (`⌘H`), Diagnostic JSON, Sanitized Config, and Import Config Profile.
7. **Automation Rules Tab ([`AutomationRulesTab.swift`](tabs/AutomationRulesTab.swift), `⌘A`)**:
   - Declarative `When -> Do` rule builder (including non-numeric `.systemWillSleep` event triggers), preset loader, dry-run simulation, and execution audit log.
