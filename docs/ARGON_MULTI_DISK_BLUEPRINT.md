# Actionable Execution Blueprint: Multi-Disk Unification & Insights Architecture

This blueprint specifies the deterministic, phase-by-phase architectural transformation of `disk-health-monitor` from a single-target monitor into a simultaneous multi-disk telemetry, alerting, and comparative analytics engine while preserving 100% backward compatibility with existing configurations, CLI scripts, and unit tests.

---

## 1. Architectural Diff & System Impact Matrix

| File Path | Action | Architectural Responsibility & Summary of Changes |
| :--- | :---: | :--- |
| `src/models/HealthModels.swift` | **Modify** | Bump version to `2.4.0`. Add `Identifiable` to `DiskHealthSnapshot` (`driveKey`). Introduce `MultiDiskHealthSnapshot` for aggregate fleet telemetry, worst-case severity, min health score, and active snapshot dictionary/array. Enhance `DriveBaselineState` with transient I/O throughput delta tracking (`lastBytesRead`, `lastBytesWritten`, `lastSampleTimestamp`). |
| `src/config/ConfigManager.swift` | **Modify** | Extend `DiskHealthConfig` with `monitorAllDisks: Bool = false` and `monitoredTargets: [String] = []`. Maintain full JSON & `.env` backward compatibility with `targetVolumePath` and `targetDeviceQuery`. Add thread-safe multi-target helpers (`setMonitorAllDisks`, `toggleTargetInMonitoredList`). |
| `src/engine/CanaryProbeService.swift` | **Modify** | Refactor single `lastRunTime` / `cachedResult` into a per-mount dictionary (`cacheByMount: [String: (timestamp: TimeInterval, result: CanaryProbeResult)]`) so multi-disk polling does not cross-contaminate canary probe caches across volumes. |
| `src/engine/TelemetryProvider.swift` | **Modify** | Update `MockTelemetryProvider` to support per-query hardware metrics (`hardwareMetricsByQuery: [String: DiskHardwareMetrics]`) and per-mount filesystem metrics (`filesystemMetricsByMount: [String: FilesystemMountMetrics]`) while keeping fallback properties for existing single-disk tests. |
| `src/engine/DiskHealthMonitor.swift` | **Modify** | Add `@Published private(set) var publishedMultiSnapshot: MultiDiskHealthSnapshot?` and `@Published var selectedDashboardDriveKey: String = ""`. Implement `evaluateAllMonitoredDisks(...)` and refactor `evaluateHealth(...)` to delegate seamlessly while maintaining legacy single-snapshot return contracts. Handle dynamic external disk unmounts gracefully in `monitorAllDisks` mode without false CRITICAL alerts. |
| `src/diagnostics/DiagnosticExporter.swift` | **Modify** | Include `"monitoredFleet"` array of all evaluated `DiskHealthSnapshot` objects in JSON diagnostic reports and add a Multi-Disk Fleet Overview table to HTML RMA reports. |
| `src/main.swift` | **Modify** | Add `--all` CLI flag. Support multi-disk output in `--status`, `--check`, and `--json --all`. |
| `src/ui/AppDelegate.swift` | **Modify** | Update Menu Bar status item to reflect worst-case severity across all monitored disks (`MultiDiskHealthSnapshot`). Add "Monitor All Connected Disks" toggle and per-drive quick status badges in the `Select Monitored Disk` menu. Add "Health Statistics & Insights..." menu item (`Cmd+S`). |
| `src/ui/DashboardMenuView.swift` | **Modify** | Add a compact horizontal multi-disk switcher bar at the top of the Menu Bar popover when monitoring multiple drives, allowing instant switching between drives inside the popover. |
| `src/ui/tabs/StatisticsAndInsightsTab.swift` | **Create** | New dedicated comparative Statistics & Insights view featuring: Fleet Summary Header, Comparative Endurance & TBW Burn-Rate Matrix, Thermal Profile Comparison Bars, Kernel I/O Latency & Throughput Comparison, Canary Latency & Error Matrix, and Interactive Per-Disk Raw S.M.A.R.T. Register Breakdown. |
| `src/ui/SettingsView.swift` | **Modify** | Expand window dimensions to `760x660` and add the new `(3, "Statistics", "chart.bar.xaxis")` tab alongside `General`, `Thresholds`, `Notifications`, `S.M.A.R.T.`, and `Diagnostics`. |
| `src/ui/SettingsViewModel.swift` | **Modify** | Add multi-disk selection helpers (`toggleMonitorAllDisks`, `isTargetSelected`, `toggleDiskSelection`) and unify disk enumeration. |
| `src/ui/tabs/GeneralSettingsTab.swift` | **Modify** | Add "Monitor All Connected Disks" toggle and multi-select checklist of detected physical disks and volumes. |
| `src/ui/tabs/SmartInspectorTab.swift` | **Modify** | Add drive selector picker at the top of the S.M.A.R.T. Inspector so users can inspect registers for any monitored drive. |
| `tests/test_core_logic.swift` | **Modify** | Preserve all 33 existing unit tests and add new multi-disk evaluation, per-mount canary caching, dynamic external drive ejection, and config migration tests. |

---

## 2. Schema & Model Contracts

### 2.1 `DiskHealthConfig` (`src/config/ConfigManager.swift`)
```swift
struct DiskHealthConfig: Codable, Equatable {
    var targetVolumePath: String? = nil
    var targetDeviceQuery: String? = nil
    var monitorAllDisks: Bool = false
    var monitoredTargets: [String] = []
    var requiredSubpaths: [String] = []
    var enableActiveCanary: Bool = true
    var pollIntervalSeconds: TimeInterval = 30.0
    var alertCooldownSeconds: TimeInterval = 3600.0
    var tempWarningCelsius: Int = 58
    var tempCriticalCelsius: Int = 68
    var diskUsedWarningPercent: Double = 85.0
    var diskUsedCriticalPercent: Double = 93.0
    var minFreeSpaceCriticalGB: Double = 15.0
    var minFreeSpaceWarningGB: Double = 30.0
    var minExpectedUsbSpeedBps: UInt64 = 5_000_000_000
    var enableNativeNotifications: Bool = true
    var enableCriticalSoundAlert: Bool = false
    var scheduledVerifyIntervalHours: Int = 0
    var telegramBotToken: String = ""
    var telegramChatId: String = ""
    var webhookUrl: String = ""
    var alertScriptPath: String = ""
    var useKeychainStorage: Bool = false

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = DiskHealthConfig()
        targetVolumePath = try container.decodeIfPresent(String.self, forKey: .targetVolumePath) ?? defaults.targetVolumePath
        targetDeviceQuery = try container.decodeIfPresent(String.self, forKey: .targetDeviceQuery) ?? defaults.targetDeviceQuery
        monitorAllDisks = try container.decodeIfPresent(Bool.self, forKey: .monitorAllDisks) ?? defaults.monitorAllDisks
        monitoredTargets = try container.decodeIfPresent([String].self, forKey: .monitoredTargets) ?? defaults.monitoredTargets
        requiredSubpaths = try container.decodeIfPresent([String].self, forKey: .requiredSubpaths) ?? defaults.requiredSubpaths
        enableActiveCanary = try container.decodeIfPresent(Bool.self, forKey: .enableActiveCanary) ?? defaults.enableActiveCanary
        pollIntervalSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .pollIntervalSeconds) ?? defaults.pollIntervalSeconds
        alertCooldownSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .alertCooldownSeconds) ?? defaults.alertCooldownSeconds
        tempWarningCelsius = try container.decodeIfPresent(Int.self, forKey: .tempWarningCelsius) ?? defaults.tempWarningCelsius
        tempCriticalCelsius = try container.decodeIfPresent(Int.self, forKey: .tempCriticalCelsius) ?? defaults.tempCriticalCelsius
        diskUsedWarningPercent = try container.decodeIfPresent(Double.self, forKey: .diskUsedWarningPercent) ?? defaults.diskUsedWarningPercent
        diskUsedCriticalPercent = try container.decodeIfPresent(Double.self, forKey: .diskUsedCriticalPercent) ?? defaults.diskUsedCriticalPercent
        minFreeSpaceCriticalGB = try container.decodeIfPresent(Double.self, forKey: .minFreeSpaceCriticalGB) ?? defaults.minFreeSpaceCriticalGB
        minFreeSpaceWarningGB = try container.decodeIfPresent(Double.self, forKey: .minFreeSpaceWarningGB) ?? defaults.minFreeSpaceWarningGB
        minExpectedUsbSpeedBps = try container.decodeIfPresent(UInt64.self, forKey: .minExpectedUsbSpeedBps) ?? defaults.minExpectedUsbSpeedBps
        enableNativeNotifications = try container.decodeIfPresent(Bool.self, forKey: .enableNativeNotifications) ?? defaults.enableNativeNotifications
        enableCriticalSoundAlert = try container.decodeIfPresent(Bool.self, forKey: .enableCriticalSoundAlert) ?? defaults.enableCriticalSoundAlert
        scheduledVerifyIntervalHours = try container.decodeIfPresent(Int.self, forKey: .scheduledVerifyIntervalHours) ?? defaults.scheduledVerifyIntervalHours
        telegramBotToken = try container.decodeIfPresent(String.self, forKey: .telegramBotToken) ?? defaults.telegramBotToken
        telegramChatId = try container.decodeIfPresent(String.self, forKey: .telegramChatId) ?? defaults.telegramChatId
        webhookUrl = try container.decodeIfPresent(String.self, forKey: .webhookUrl) ?? defaults.webhookUrl
        alertScriptPath = try container.decodeIfPresent(String.self, forKey: .alertScriptPath) ?? defaults.alertScriptPath
        useKeychainStorage = try container.decodeIfPresent(Bool.self, forKey: .useKeychainStorage) ?? defaults.useKeychainStorage
    }
}
```

### 2.2 `MultiDiskHealthSnapshot` & `DiskHealthSnapshot` Extensions (`src/models/HealthModels.swift`)
```swift
extension DiskHealthSnapshot: Identifiable {
    var driveKey: String {
        if !serialNumber.isEmpty { return serialNumber }
        if !bsdName.isEmpty { return bsdName }
        if !mountPoint.isEmpty { return mountPoint }
        return "\(vendorName)-\(productName)"
    }

    var id: String { driveKey }

    var displayLabel: String {
        let model = "\(vendorName) \(productName)".trimmingCharacters(in: .whitespaces)
        if !bsdName.isEmpty {
            return "\(model) (\(bsdName))"
        }
        return model
    }
}

struct MultiDiskHealthSnapshot: Codable, Sendable, Equatable {
    let timestamp: TimeInterval
    let formattedTime: String
    let formattedShortTime: String
    let overallSeverity: HealthSeverity
    let worstHealthScore: Int
    let averageHealthScore: Int
    let totalIssuesCount: Int
    let disks: [DiskHealthSnapshot]

    var primarySnapshot: DiskHealthSnapshot? {
        disks.max(by: { a, b in
            if a.overallSeverity.rank != b.overallSeverity.rank {
                return a.overallSeverity.rank < b.overallSeverity.rank
            }
            return a.healthScore > b.healthScore
        }) ?? disks.first
    }
}
```

---

## 3. Step-by-Step Phased Implementation Instructions

### Phase 1: Config & Domain Models (`HealthModels.swift`, `ConfigManager.swift`, `CanaryProbeService.swift`)

#### 1.1 Update `src/models/HealthModels.swift`:
1. Update `kAppVersion = "2.4.0"` and `kAppBuildNumber = "7"`.
2. Add `DiskHealthSnapshot: Identifiable` extension with `driveKey`, `id`, and `displayLabel` as shown in Section 2.2.
3. Add `MultiDiskHealthSnapshot` struct as shown in Section 2.2.

#### 1.2 Update `src/config/ConfigManager.swift`:
1. Add `var monitorAllDisks: Bool = false` and `var monitoredTargets: [String] = []` to `DiskHealthConfig` and decode them in `init(from decoder: Decoder)` using `decodeIfPresent`.
2. In `loadDotEnvWithWebhook` and `applyEnvironmentVariables`, parse:
   - `MONITOR_ALL_DISKS`: `result.monitorAllDisks = (val.lowercased() == "true" || val == "1" || val.lowercased() == "yes")`
   - `DISK_HEALTH_TARGETS`: `result.monitoredTargets = val.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }`
3. Add `overrideMonitorAll(_ all: Bool)` to `ConfigManager` for CLI `--all` invocations:
   ```swift
   func overrideMonitorAll(_ all: Bool) {
       configLock.lock()
       var next = self._config
       next.monitorAllDisks = all
       self._config = next
       configLock.unlock()
       notifyObjectWillChangeOnMain()
   }
   ```

#### 1.3 Update `src/engine/CanaryProbeService.swift`:
1. Replace `lastRunTime: TimeInterval` and `cachedResult: CanaryProbeResult` with a per-mount dictionary:
   ```swift
   private var cacheByMount: [String: (timestamp: TimeInterval, result: CanaryProbeResult)] = [:]
   ```
2. In `resetCache()`, call `cacheByMount.removeAll()`.
3. In `runCanaryCheck(targetMount: String, force: Bool, nowTs: TimeInterval)`:
   - Normalize key: `let key = targetMount.isEmpty ? "/" : targetMount`
   - Check `if !force, let entry = cacheByMount[key], (nowTs - entry.timestamp) < 300, entry.timestamp > 0 { return entry.result }`
   - After probing, store `cacheByMount[key] = (timestamp: nowTs, result: result)`.

---

### Phase 2: Core Engine & Polling Loop (`TelemetryProvider.swift`, `DiskHealthMonitor.swift`)

#### 2.1 Update `src/engine/TelemetryProvider.swift`:
1. Enhance `MockTelemetryProvider` so tests can register multiple simulated disks while preserving existing single-disk test compatibility:
   ```swift
   var hardwareMetricsByQuery: [String: DiskHardwareMetrics] = [:]
   var filesystemMetricsByMount: [String: FilesystemMountMetrics] = [:]
   ```
2. In `MockTelemetryProvider.readHardwareMetrics(query: String)`:
   - First check `if let specific = hardwareMetricsByQuery[query] { return specific }`
   - Next check `allDevices` for a matching `bsdName` or `serialNumber`:
     ```swift
     if let match = allDevices.first(where: { cStringToSwift($0.bsdName) == query || (!cStringToSwift($0.serialNumber).isEmpty && cStringToSwift($0.serialNumber) == query) }) {
         return match
     }
     ```
   - Fallback to `return hardwareMetrics`.
3. In `MockTelemetryProvider.inspectFilesystem(mountPath: String)`:
   - First check `if let specific = filesystemMetricsByMount[mountPath] { return specific }`
   - Fallback to `return filesystemMetrics`.

#### 2.2 Overhaul `src/engine/DiskHealthMonitor.swift` for Simultaneous Multi-Disk Monitoring:
1. Add published properties and per-drive throughput sample tracking:
   ```swift
   @Published private(set) var publishedMultiSnapshot: MultiDiskHealthSnapshot?
   private var latestMultiSnapshotInternal: MultiDiskHealthSnapshot?

   @Published var selectedDashboardDriveKey: String = ""

   var currentMultiSnapshot: MultiDiskHealthSnapshot? {
       engineLock.lock()
       defer { engineLock.unlock() }
       return latestMultiSnapshotInternal
   }

   private struct DriveThroughputSample {
       var bytesRead: UInt64 = 0
       var bytesWritten: UInt64 = 0
       var timestamp: TimeInterval = 0
   }
   private var throughputSamplesByDrive: [String: DriveThroughputSample] = [:]
   ```
2. In `clearCurrentSnapshotForTesting()`, also reset `latestMultiSnapshotInternal = nil`, `throughputSamplesByDrive.removeAll()`, and set `publishedMultiSnapshot = nil` on main thread.
3. Extract a private helper `evaluateSingleTargetLocked(targetMount: String, targetQuery: String, preloadedHardware: DiskHardwareMetrics?, isAutoDiscovered: Bool, forceCanary: Bool, allowNotifications: Bool, now: Date, provider: any DiskTelemetryProvider) -> DiskHealthSnapshot`:
   - Uses `preloadedHardware` if provided (e.g. when `monitorAllDisks` enumerates `provider.listAllDevices(maxCount: 32)`), otherwise queries `provider.readHardwareMetrics(query: queryToPass)`.
   - Computes throughput delta per `driveKey` using `throughputSamplesByDrive[driveKey]` so multiple drives polled in the same cycle never overwrite each other's `previousBytesRead` / `previousBytesWritten` / `previousSampleTime`.
   - **Dynamic Ejection Guardrail**: When `isAutoDiscovered == true` (from `monitorAllDisks`), if a physical external disk has no mounted partition (`!fsMetrics.isMounted`), `mountToInspect` is passed as `""` so an unmounted external drive does not trigger a false `VOLUME_UNMOUNTED` critical alert.
   - Evaluates `StandardHealthRulePipeline.defaultRules`, updates `state.drives[driveKey]`, and invokes `processAlertsAndDigestLocked(snapshot: snapshot, rawMetrics: hw, driveKey: driveKey, sendDailyDigest: false)` when `allowNotifications == true`.
4. Implement `evaluateAllMonitoredDisks(forceCanary: Bool = false, allowNotifications: Bool = true, telemetryProvider: (any DiskTelemetryProvider)? = nil) -> MultiDiskHealthSnapshot`:
   - Resolves target list based on `ConfigManager.shared.currentConfig`:
     - **Case A (`cfg.monitorAllDisks == true`)**: Calls `provider.listAllDevices(maxCount: 32)`. Filters `found == true`, deduplicates by `serialNumber` / `bsdName`. If non-empty, evaluates each device via `evaluateSingleTargetLocked(..., preloadedHardware: dev, isAutoDiscovered: true, ...)`. If `listAllDevices` returns empty (e.g. in a single-disk unit test where only `hardwareMetrics` was populated), falls back to single-target evaluation.
     - **Case B (`!cfg.monitoredTargets.isEmpty`)**: Iterates over `cfg.monitoredTargets` (deduplicated), routing paths starting with `"/"` as `targetMount` and device identifiers as `targetQuery`.
     - **Case C (Single Target / Legacy Default)**: Evaluates `(targetMount: cfg.targetVolumePath ?? "", targetQuery: cfg.targetDeviceQuery ?? "")`.
   - Aggregates `disks: [DiskHealthSnapshot]` into `MultiDiskHealthSnapshot`:
     - `overallSeverity`: highest severity rank across `disks`.
     - `worstHealthScore`: `disks.map(\.healthScore).min() ?? 100`.
     - `averageHealthScore`: average of `disks.map(\.healthScore)`.
     - `totalIssuesCount`: `disks.reduce(0) { $0 + $1.issues.count }`.
   - Selects active `primarySnapshot`:
     - If `selectedDashboardDriveKey` matches a disk in `disks`, use that disk for `publishedSnapshot` (or if single-target mode, use `disks.first`). Otherwise default `selectedDashboardDriveKey` to `multi.primarySnapshot?.driveKey ?? ""`.
   - Persists `latest_status.json` and `state.json`, dispatches Daily Digest once per day across the fleet, and publishes both `publishedMultiSnapshot` and `publishedSnapshot` on the main thread.
5. Keep `evaluateHealth(forceCanary: Bool = false, allowNotifications: Bool = true, telemetryProvider: (any DiskTelemetryProvider)? = nil) -> DiskHealthSnapshot`:
   - Calls `let multi = evaluateAllMonitoredDisks(forceCanary: forceCanary, allowNotifications: allowNotifications, telemetryProvider: telemetryProvider)`
   - Returns `multi.disks.first(where: { $0.driveKey == selectedDashboardDriveKey }) ?? multi.primarySnapshot ?? multi.disks.first!`.
   - This guarantees 100% compatibility with all 33 existing unit tests while powering multi-disk monitoring everywhere.

---

### Phase 3: CLI & Exporters (`DiagnosticExporter.swift`, `main.swift`)

#### 3.1 Update `src/diagnostics/DiagnosticExporter.swift`:
1. In `generateDiagnosticReport(snapshot: DiskHealthSnapshot? = nil)`:
   - Fetch `let multi = DiskHealthMonitor.shared.currentMultiSnapshot ?? DiskHealthMonitor.shared.evaluateAllMonitoredDisks(forceCanary: true, allowNotifications: false)`
   - Add `"monitoredFleet"` key to the returned dictionary containing per-disk summaries (`driveKey`, `bsdName`, `vendorName`, `productName`, `serialNumber`, `mountPoint`, `overallSeverity`, `healthScore`, `temperatureCelsius`, `lifeRemainingPercent`, `totalTerabytesWritten`, `issuesCount`) and `"target"` metadata (`"monitorAllDisks": cfg.monitorAllDisks`, `"monitoredTargets": cfg.monitoredTargets`).
2. In `exportDiagnosticReportHTML(snapshot: DiskHealthSnapshot? = nil)`:
   - If `multi.disks.count > 1`, render a **"Multi-Disk Fleet Overview"** table card above the detailed primary drive report showing each monitored drive's Model, BSD Name, Mount Point, Temperature, Wear Remaining, TBW, Health Score, and Status Badge.

#### 3.2 Update `src/main.swift`:
1. In `printUsage()`, document `--all`:
   ```
      --all                 Monitor and evaluate all connected physical disks simultaneously
   ```
2. In `parseCommandLine()`:
   - If `args.contains("--all")`, call `ConfigManager.shared.overrideMonitorAll(true)`.
   - In `--json`:
     - If `args.contains("--all")` or `ConfigManager.shared.currentConfig.monitorAllDisks` or `ConfigManager.shared.currentConfig.monitoredTargets.count > 1`:
       - When `args.contains("--all")`, encode `MultiDiskHealthSnapshot` (or if single-target `--json` without `--all`, preserve exact `DiskHealthSnapshot` root JSON schema so existing CLI tests expecting `"overallSeverity"` at root pass). Note: `MultiDiskHealthSnapshot` also has `"overallSeverity"` at root!
   - In `isCheckMode`:
     - If `ConfigManager.shared.currentConfig.monitorAllDisks` or `ConfigManager.shared.currentConfig.monitoredTargets.count > 1`:
       - Call `let multi = DiskHealthMonitor.shared.evaluateAllMonitoredDisks(forceCanary: true, allowNotifications: notify)`
       - Print the aggregate header (`DISK HEALTH MONITOR — <SEVERITY> (Score: <worstScore>/100) [Fleet: N Disks]`) followed by each drive's telemetry block.
       - Exit with `Int32(multi.overallSeverity.rank)`.

---

### Phase 4: SwiftUI Menu Bar & Dashboard (`AppDelegate.swift`, `DashboardMenuView.swift`)

#### 4.1 Update `src/ui/AppDelegate.swift`:
1. Add a menu item in `setupMenu()` right below `Inspect Raw S.M.A.R.T. & Hardware Counters...`:
   ```swift
   let statsItem = NSMenuItem(title: "Health Statistics & Comparative Insights...", action: #selector(openStatisticsTab), keyEquivalent: "s")
   statsItem.target = self
   menu.addItem(statsItem)
   ```
2. Implement `@objc func openStatisticsTab()` to open Settings at the new Statistics tab (`tab: 3`, shifting S.M.A.R.T. to `tab: 4` and Diagnostics to `tab: 5`, or keeping S.M.A.R.T. at `3`, Statistics at `4`, Diagnostics at `5` — **IMPORTANT**: keep `SmartInspectorTab` at `tab: 3` or update `openSmartInspector()` so `openSmartInspector()` always opens the S.M.A.R.T. tab!).
   - Specifically:
     - Tab 0: `General`
     - Tab 1: `Thresholds`
     - Tab 2: `Notifications`
     - Tab 3: `S.M.A.R.T.` (preserves `showSettings(tab: 3)` contract)
     - Tab 4: `Statistics` (`Health Statistics & Insights`)
     - Tab 5: `Diagnostics`
3. In `populateSelectDiskMenu()`:
   - Add **"Monitor All Connected Disks"** item at the very top (`representedObject = "all_disks"`), with `.state = cfg.monitorAllDisks ? .on : .off`.
   - Below the separator, list physical disks and mounted volumes. If `multiSnapshot` has a snapshot for a disk, append its status emoji and temperature (e.g., `🟢 38°C`) to the menu item title for instant at-a-glance visibility.
4. In `selectDiskTarget(_ sender: NSMenuItem)`:
   - Handle `"all_disks"` by toggling `ConfigManager.shared.updateConfig { $0.monitorAllDisks.toggle(); if $0.monitorAllDisks { $0.monitoredTargets.removeAll() } }`.
   - When a specific disk is clicked while `monitorAllDisks` is active, set `DiskHealthMonitor.shared.selectedDashboardDriveKey` to that disk's key and disable `monitorAllDisks` if the user explicitly picks a single target (or switch the active dashboard card).
5. In `refreshHealth(forceCanary: Bool)`:
   - Call `let multi = DiskHealthMonitor.shared.evaluateAllMonitoredDisks(forceCanary: forceCanary, allowNotifications: true)`
   - Update the status bar button using `updateStatusBarButton(with: multi)`.
6. In `updateStatusBarButton(with multi: MultiDiskHealthSnapshot)`:
   - Use `multi.overallSeverity` for the icon (`externaldrive.fill.badge.checkmark`, `externaldrive.trianglebadge.exclamationmark`, `externaldrive.fill.badge.xmark`).
   - If `multi.disks.count > 1`:
     - Display fleet badge: e.g. `" \(multi.disks.count) Disks 🚨"` (if critical), `" \(multi.disks.count) Disks ⚠️"` (if warning), or `" \(multi.disks.count) Disks \(maxTemp)°C"` (if healthy).
   - If `multi.disks.count == 1`, use the exact single-drive title format.

#### 4.2 Update `src/ui/DashboardMenuView.swift`:
1. Observe `monitor.publishedMultiSnapshot`.
2. When `multi.disks.count > 1`, render a sleek horizontal `ScrollView(.horizontal, showsIndicators: false)` pill switcher at the top of the popover showing each monitored disk (`🟢 disk0 • 36°C`, `🟡 External • 59°C`). Clicking a pill sets `monitor.selectedDashboardDriveKey = disk.driveKey`.
3. Render the detailed card below for the selected disk (`multi.disks.first(where: { $0.driveKey == monitor.selectedDashboardDriveKey }) ?? multi.primarySnapshot`).

---

### Phase 5: New Statistics & Insights View (`StatisticsAndInsightsTab.swift`, `SettingsView.swift`, `GeneralSettingsTab.swift`, `SmartInspectorTab.swift`)

#### 5.1 Create `src/ui/tabs/StatisticsAndInsightsTab.swift`:
Design a comprehensive, high-contrast macOS native SwiftUI view (`StatisticsAndInsightsTab`) containing:
1. **Fleet Health Overview Banner (`SettingsCard`)**:
   - Aggregate metrics pills: **Monitored Drives Count**, **Fleet Status & Worst/Avg Score**, **Combined Lifetime Written (TBW)**, **Peak Fleet Temperature**, and a **"Refresh All Telemetry"** button.
2. **Drive Lifetime & Endurance Comparison (`SettingsCard`)**:
   - Side-by-side / stacked comparative rows for every monitored drive showing:
     - Drive Name & BSD badge
     - Visual wear gauge (`lifeRemainingPercent%` left vs `percentageUsed%` used)
     - Total Terabytes Written (`TBW`) & Total Terabytes Read
     - Daily Write Burn Rate (`GB/day` or `TB/day`)
     - Projected Remaining Lifespan (`estimatedRemainingLifeFormatted`)
     - Available Spare blocks (`availableSpare%` vs threshold)
3. **Operating Temperature Profile (`SettingsCard`)**:
   - Visual horizontal thermal range bar for each drive comparing:
     - Current Temperature (`°C`)
     - Recorded Peak Temperature (`°C`)
     - Configured Warning (`tempWarningCelsius`) & Critical (`tempCriticalCelsius`) markers
4. **I/O Latency, Throughput & Active Canary Trends (`SettingsCard`)**:
   - Comparative breakdown per drive of:
     - Live Read / Write Throughput (`MB/s`)
     - Average Kernel Driver Read / Write Latency (`ms`) via `IOBlockStorageDriver`
     - Active Filesystem Canary Probe Latency (`ms`) & status badge (`PASSED` / `FAILED`)
     - Kernel Read/Write Errors, Retries, Media Errors, and Unsafe Shutdown counters
5. **Comparative Raw S.M.A.R.T. Register Breakdown (`SettingsCard`)**:
   - Interactive drive selector or multi-column matrix allowing instant inspection of all 14 NVMe S.M.A.R.T. registers (`01` Critical Warning through `0E` Error Info Log Entries) across monitored drives.

#### 5.2 Update `src/ui/tabs/GeneralSettingsTab.swift` & `src/ui/tabs/SmartInspectorTab.swift`:
1. In `GeneralSettingsTab`:
   - Add a **"Monitor All Connected Disks"** switch (`configMgr.config.monitorAllDisks`).
   - Add a **"Multi-Disk Selection"** collapsible or scrollable checklist when the user wants to monitor a specific subset of drives (`configMgr.config.monitoredTargets`), while keeping the primary **Target Drive or Volume** `Picker` for single-target selection.
2. In `SmartInspectorTab`:
   - When multiple disks are monitored (`monitor.currentMultiSnapshot?.disks.count ?? 0 > 1`), display a `Picker("Inspect Drive", selection: $monitor.selectedDashboardDriveKey)` in the header card so the user can switch between any monitored drive's raw S.M.A.R.T. and kernel driver counters.

---

### Phase 6: Test Suite Extensions (`tests/test_core_logic.swift`)

Add deterministic unit tests in `tests/test_core_logic.swift` verifying:
1. **Multi-Disk Config Serialization & Backward Compatibility**:
   - Decoding legacy `config.json` without `monitorAllDisks` or `monitoredTargets` defaults cleanly (`monitorAllDisks == false`, `monitoredTargets == []`).
   - Encoding and decoding `monitorAllDisks: true` and `monitoredTargets: ["disk0", "/Volumes/Backup"]` preserves all fields.
2. **Simultaneous Multi-Disk Evaluation & Worst-Case Aggregation**:
   - Configure `MockTelemetryProvider` with two drives: `disk0` (Internal NVMe, 38°C, Healthy, Score 100) and `disk2` (External USB NVMe, 62°C Warning, Score 85).
   - Enable `monitorAllDisks = true` and run `DiskHealthMonitor.shared.evaluateAllMonitoredDisks(forceCanary: false, allowNotifications: false, telemetryProvider: mock)`.
   - Assert `multi.disks.count == 2`, `multi.overallSeverity == .warning`, `multi.worstHealthScore == 85`, and `multi.averageHealthScore == 92`.
3. **Per-Mount Canary Cache Isolation**:
   - Verify `CanaryProbeService.shared` caches probe latencies independently per mount point (`/` vs `/tmp`) without returning stale cached results from another volume.
4. **Dynamic Unmounted External Disk Handling in `monitorAllDisks` Mode**:
   - Simulate an unmounted external physical disk in `monitorAllDisks` mode and verify it does not emit a false `VOLUME_UNMOUNTED` critical issue unless explicitly targeted by mount path.

---

## 4. Developer Guardrails & Directives

1. **Zero Regressions in Existing Tests**:
   - Do **not** alter any C function signatures in `DiskHealthBridge.h` / `DiskHealthBridge.c`. All 15 C unit tests in `test_disk_health_bridge.c` and all 33 Swift unit tests in `test_core_logic.swift` must continue to compile and pass.
   - `DiskHealthMonitor.shared.evaluateHealth(...)` must continue to return `DiskHealthSnapshot` and update `publishedSnapshot` and `currentSnapshot` synchronously under `engineLock`.
2. **Thread Safety & Lock Discipline**:
   - Never hold `ConfigManager.configLock` while acquiring `DiskHealthMonitor.engineLock` (always read `ConfigManager.shared.currentConfig` before or inside `engineLock`, never call `DiskHealthMonitor` from inside `ConfigManager.updateConfig`).
   - Ensure all `@Published` property mutations (`publishedSnapshot`, `publishedMultiSnapshot`, `isVerifyingVolume`) occur on the main thread or via `DispatchQueue.main.async`.
3. **macOS 13+ SwiftUI Compatibility**:
   - Do not use macOS 14+ exclusive APIs (such as `.onChange(of:initial:_:)` two-parameter closure syntax or `@Observable` macro). Use macOS 13 compatible `.onChange(of:) { newValue in ... }` and `ObservableObject` / `@ObservedObject`.
4. **Build & Test Verification**:
   - Because `build_and_install.sh` and `tests/run_tests.sh` automatically glob all `*.swift` files under `src/`, any new Swift file placed in `src/ui/tabs/StatisticsAndInsightsTab.swift` will be compiled automatically into both the app bundle and `test_core_logic`.
