> [!IMPORTANT]
> # CRITICAL AGENT DIRECTIVE: ALWAYS KEEP THIS DOCUMENT UP TO DATE
> Every AI agent or developer modifying this repository MUST synchronize and update this document (`AGENTS.md`) immediately upon completing any code, architecture, configuration, or documentation changes. Never leave this file stale.

# AGENTS.md — Universal Disk Health Monitor (`v2.8.0` Build `11`)

Definitive LLM/Agent reference for `disk-health-monitor`. Token-optimized. Zero fluff.

---

## 1. PROJECT IDENTITY & CORE CONSTRAINTS

- **Name**: Universal Disk Health Monitor (`DiskHealthMonitor.app` / `./disk-health` CLI symlink)
- **Version**: `v2.8.0` (Build `11`), Bundle ID: `io.github.disk-health-monitor`
- **Platform**: macOS 13.0+ (Ventura through macOS 15+ Sequoia). Universal Mach-O Binary (`arm64` Apple Silicon + `x86_64` Intel).
- **Zero External Dependencies**: Compiled directly via `build_and_install.sh` using `clang` (`-O2 -Wall -Wextra`) and `swiftc` (`-O -whole-module-optimization -Xlinker -dead_strip`). Links only native Apple frameworks (`Cocoa`, `SwiftUI`, `IOKit`, `CoreFoundation`, `UserNotifications`, `Security`, `UniformTypeIdentifiers`) and Darwin/POSIX libc. No SwiftPM, no CocoaPods, no Swift 5.9+ macro plugins (`@Observable` and `@State` prohibited in standalone `swiftc` builds; use `ObservableObject` / `@Published`).
- **Dual-Mode Single Binary**:
  - **Headless CLI / LaunchAgent**: Synchronous execution with deterministic exit codes (`0` = `HEALTHY`, `1` = `WARNING` / CLI error, `2` = `CRITICAL` / scan failure, `64` = unknown CLI flag).
  - **Menu Bar Agent (`LSUIElement = true`)**: Detaches from controlling TTY via `posix_spawn` (`POSIX_SPAWN_SETSID`), acquires non-blocking `flock` on `~/.config/disk-health-monitor/menubar.lock`, runs `NSApplication` status bar item + popover + 7-tab Settings window (`820x700`).

---

## 2. ARCHITECTURAL TOPOLOGY & SUBSYSTEMS

### Layer 1: C11 / IOKit Hardware Bridge (`src/bridge/`)
- **`src/bridge/DiskHealthBridge.h` & `src/bridge/DiskHealthBridge.c`**:
  - **Role**: Low-level IOKit registry traversal (`IOBlockStorageDevice`, `IOBlockStorageDriver`, `IOMedia`), NVMe SMART Log Page `02h` (`IONVMeSMARTUserClient` COM vtable), and VFS mount resolution (`getfsstat`).
  - **Key Functions**:
    - `DiskReadHardwareMetrics(targetIdentifier, outMetrics)`
    - `DiskListAllDevices(outArray, maxCount)`
    - `DiskFindMountForBlockDevice(deviceBsdName, outMountPoint, maxLen)`
    - `DiskConvertNVMeTemperature(tempRaw)` (validates `233K..423K` $\rightarrow$ `-40°C..150°C`, direct Celsius `1..150`, else `0`)
    - `DiskDecodeNVMeLE128(bytes)` (128-bit little-endian to `uint64_t` with `UINT64_MAX` saturation if upper 64 bits non-zero)
    - `DiskNormalizeLinkSpeedToBps(rawSpeed)` (maps USB speed codes `1..5` $\rightarrow$ `12M, 480M, 5G, 10G, 20G` bps; passes raw bps $\ge 1\text{M}$ through)
    - `DiskExtractCFNumberU64(dict, key)` (clamps negative signed integers to `0`)
    - `DiskSampleProcessIoMetrics(outArray, maxCount)` (Darwin `<libproc.h>` `proc_listallpids` + `proc_pid_rusage(RUSAGE_INFO_V4)` per-PID `ri_diskio_bytesread` / `ri_diskio_byteswritten` sampler)
  - **Bridge Invariants**:
    - **APFS Subtree Pruning (`C11-01`)**: `inspectChildrenForDriverStatsRecursive` (max depth 12) prunes `AppleAPFSContainerScheme`, `AppleAPFSContainer`, `AppleAPFSMedia`, and `AppleAPFSVolume` before checking `Whole == true` on `IOMedia`. Prevents virtual APFS containers from clobbering physical whole-disk `bsdName`.
    - **Static Cache & Live BSD Name (`OPT-01`, `UAT2-03`, `BRIDGE-04`)**: 64-entry ring buffer `sStaticCache` protected by `sStaticCacheMutex` (`pthread_mutex_t`), keyed by `IORegistryEntryGetRegistryEntryID`. Caches invariant strings (`productName`, `vendorName`, `serialNumber`, `interconnectType`, `linkSpeedBps`, `usbCurrentAvailableMa`, `usbCurrentRequiredMa`, `linkWidthLanes`), skips virtual disk images (`isVirtualDiskDevice`), and **deliberately omits restoring `bsdName` on cache hit** so `inspectChildrenForDriverStats` always queries live `IOMedia` child (preventing stale BSD names after USB hot-replug).
    - **Bus Precedence, USB Power & Lane Width (`SYS-06`, `BRIDGE-02`, `v2.8.0`)**: `inspectParentsForBusProperties` (max depth 16) evaluates parent class (`USB`, `Thunderbolt`, `DiskImage`/`HDIX`, `AHCI`/`SATA`, `PCI`/`NVMe`) before normalizing link speed. Extracts USB bus power budgets (`kUSBHostPortPropertyCurrentAllocation`, `bMaxPower`, `Current Available`, `Sleep Current`) and PCIe/Thunderbolt link width (`LINK-WIDTH`, `Current Link Width`). USB enum codes `1..5` are only mapped via `DiskNormalizeLinkSpeedToBps` when in a confirmed USB context (`UsbLinkSpeed`, `Device Speed`, or `IOUSB*` parent), preventing PCIe link gen numbers (`1..5`) from misclassifying as USB speeds.
    - **Mount Resolution Fast-Path (`OPT2-02`, `MISSED-04`)**: `DiskFindMountForBlockDevice` uses stack-allocated `struct statfs stackFs[64]` (falling back to `calloc` only if mounts $> 64$) and candidate score pruning (`10` = exact slice match, `6` = `/`, `5` = writable `/Volumes/*`, `4` = RO `/Volumes/*`, `3` = `/System/Volumes/Data`, `1` = EFI/Recovery/Preboot, `0` = `/System/Volumes/*`) to skip redundant IOKit parent walks.

### Layer 2: Domain Models, Config & Security (`src/models/`, `src/config/`, `src/security/`)
- **`src/models/HealthModels.swift`**:
  - Defines `kAppVersion = "2.8.0"`, `kAppBuildNumber = "11"`, `HealthSeverity` (`.healthy` rank 0, `.warning` rank 1, `.critical` rank 2), `HealthIssue` (`id` = `"\(code):\(detail)"`), `DriveBaselineState`, `DiskPersistentState`, `DiskHealthSnapshot`, `MultiDiskHealthSnapshot`.
  - **Declarative Rule Engine Models (`v2.8.0`)**: Defines `ActionTriggerMetric` (13 metrics), `ActionConditionOperator` (`>=`, `<=`, `>`, `<`, `==`), `ActionDriveScope` (6 scopes), `ActionExecutionType` (12 actions), `ActionRule` (with 5 built-in presets `ActionRule.builtInPresets`), `ActionExecutionStatus`, and `ActionExecutionRecord`.
  - **Composite `driveKey` (`STATE-03`, `RULE-05`)**: `DiskHealthSnapshot.isPlaceholderSerial(_:)` rejects empty/dummy serials (`00000000`, `0123456789abcdef`, `none`, `n/a`, `unknown`, `generic`, `default`, repeating chars). If serial is placeholder or duplicated across connected drives, `driveKey` falls back to `"\(serialNumber)#\(bsdName)"` or `bsdName`.
  - **Endurance Forecasting**: `dailyTerabytesWritten` ($\text{TBW} / \max(1, \text{POH}/24)$) and `estimatedRemainingLifeFormatted` (`Calibrating (< 24h POH)`, `> 10 Years (0% Wear)`, `~X.Y Years`, `Depleted (< 1% left)`).
  - **Zero-Copy C-String Bridging (`OPT2-05`)**: `cStringToSwift<T>(_ tuple: T)` slices raw bytes up to first `0` byte and trims ASCII whitespace in-place before constructing `String`.
  - **Formatters**: Thread-safe `SynchronizedDateFormatter` (`en_US_POSIX` locale, `NSLock`) for `isoTimestampFormatter`, `shortTimeFormatter`, `shortMonthDateFormatter`.
- **`src/models/DiskHealthError.swift`**:
  - `DiskHealthError: LocalizedError, Sendable, Equatable` covering all hardware, mount, canary, surface scan, verification, config, Keychain (`keychainAccessDenied`, `keychainOperationFailed`), file write, and alert script failure modes.
- **`src/security/SecretStore.swift`**:
  - **`AtomicFileWriter.writeRestricted(data:toPath:permissions:)`**: Writes sibling temp file with `open(..., O_CREAT | O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)`, `fchmod(0600)`, `fsync`, `close`, and atomic `rename()`. Zero `umask` TOCTOU window.
  - **`SecretStore` & `KeychainIntegrationState`**: Zero-prompt default (`useKeychainOptIn = false`, `.localOnlyDefault`). Never calls `SecItem*` unless `allowInteractiveKeychain == true` (explicit user click on "Onboard to macOS Keychain" in Settings). If user clicks "Deny" (`errSecAuthFailed = -25293`, `errSecUserCanceled = -128`, `errSecInteractionNotAllowed = -25308`), transitions to `.accessDenied`, auto-disables `useKeychainOptIn`, and retains secrets in `~/.config/disk-health-monitor/.secrets.json` (`0600`).
- **`src/security/SingleInstanceLock.swift`**:
  - Non-blocking exclusive lock (`flock(fd, LOCK_EX | LOCK_NB)`) on `~/.config/disk-health-monitor/menubar.lock` opened with `O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC` (`0600`). Writes current PID. Headless CLI commands bypass this lock.
- **`src/config/ConfigManager.swift`**:
  - **5-Tier Precedence**: CLI Flags (`overrideTarget`, `overrideMonitorAll`) > Process Env > `.env` file > `config.json` > Defaults.
  - **Pinned Directories (`SEC-01`, `STATE-01`)**: `configDir` defaults to `~/.config/disk-health-monitor` (`0700`, override via `DISK_HEALTH_CONFIG_DIR`). `stateDir` is pinned to `configDir` (`state.json`, `latest_status.json`). `logsDir` defaults to `"\(configDir)/logs"` (override via `DISK_HEALTH_LOGS_DIR`).
  - **`.env` Security (`SEC-01`)**: Only loads `$DISK_HEALTH_ENV_FILE` and `"\(configDir)/.env"` (plus `./.env` only if `DISK_HEALTH_DEV_DOTENV=1`). Validates files via `ConfigManager.isSecureUserOwnedFile(atPath:)` (`lstat` regular file, owned by `getuid()` or `0`, not group/world-writable `(st_mode & 0o022) == 0`).
  - **Separated Configs (`CFG-01`)**: Separates `persistedConfig` (written to `config.json`) from `_config` (effective runtime config with `.env`/env overrides). `DiskHealthConfig.validated()` clamps ranges and enforces `warn < crit`.
  - **Rotating Redacted Logger (`LOG-01`)**: `log(_:deduplicateBurstWindow: 2.0)` automatically redacts Telegram bot tokens and webhook URLs (`redactSensitiveLogText`) before writing to `health.log`, deduplicates identical messages within 2s, checks size via `lseek(fd, 0, SEEK_END)`, and rotates `health.log` $\rightarrow$ `health.log.1` at 5 MB.

### Layer 3: Telemetry & Domain Engine (`src/engine/`, `src/diagnostics/`, `src/notifications/`)
- **`src/engine/TelemetryProvider.swift`**:
  - `DiskTelemetryProvider` protocol + live `IOKitTelemetryProvider` + testable `MockTelemetryProvider`.
  - `inspectFilesystem(mountPath:)` uses `statfs(2)` and queries `URLResourceKey.volumeAvailableCapacityForImportantUsageKey` **only when `fsType == "apfs"`** (`PERF-01`) to compute `purgeableBytes` and effective `freeBytes`.
- **`src/engine/HealthRules.swift`**:
  - 12 pure functional, side-effect-free `HealthRule` structs (`StandardHealthRulePipeline.defaultRules`) taking `HealthEvaluationContext` and returning `HealthRuleOutcome` (`issues`, `scorePenalty`, `updatedTemperatureSamples`, `healVerifyFailureToSkipped`, `logMessages`):
    1. `HardwarePresenceRule` (`HW_DISCONNECTED`, -60; suppressed during 8s wake grace)
    2. `VolumeMountAndReadOnlyRule` (`VOLUME_UNMOUNTED` -50, `VOLUME_READONLY` -45; skips `/` and naturally read-only FS types: `ntfs`, `cd9660`, `udf`, `iso9660`, `cdda`, `webdav`, `devfs`, `autofs`)
    3. `RequiredSubpathsRule` (`REQUIRED_PATH_MISSING` -35; rejects `..` path traversal)
    4. `CanaryProbeRule` (`CANARY_IO_FAILED` -40, `CANARY_HIGH_LATENCY` >300ms -10)
    5. `DiskSpaceRule` (`DISK_SPACE_CRITICAL` -25, `DISK_SPACE_WARNING` -10; 1.5% value hysteresis when recovering from unhealthy state)
    6. `UsbLinkSpeedRule` (`USB_LINK_DEGRADED` -15; scoped strictly to USB/Thunderbolt interconnects)
    7. `NVMeCriticalWarningRule` (`SMART_CRITICAL_WARNING` -50 when `criticalWarning != 0`)
    8. `ThermalAndSpikeRule` (`TEMP_CRITICAL` -35, `TEMP_WARNING` -15 with $2^\circ\text{C}$ recovery hysteresis; `TEMP_RAPID_RISE` -10 on $+\ge 8^\circ\text{C}$ spike within 180s window reaching $\ge 45^\circ\text{C}$)
    9. `EnduranceAndSpareRule` (`SPARE_CRITICAL` -40, `SPARE_WARNING` <25% -15, `WEAR_CRITICAL` $\ge 95\%$ -30, `WEAR_WARNING` $\ge 80\%$ -10)
    10. `SMARTIntegrityAndShutdownRule` (`MEDIA_ERRORS` -45, `ERROR_LOG_INCREASED` -15 requiring $\Delta \ge 5$ on healthy internal Apple SSDs (`RULE-07`), `NEW_UNSAFE_SHUTDOWN` -15)
    11. `DriverStatsAndLatencyRule` (`IO_DRIVER_ERRORS` -40, `IO_DRIVER_RETRIES` -10, `IO_LATENCY_CRITICAL` >200ms -25, `IO_LATENCY_WARNING` >50ms -10 when ops $\ge 100$)
    12. `HostThermalAndVerifyRule` (`HOST_THERMAL_CRITICAL` -10 scoped strictly to `hardware.isInternal` (`RULE-06`); `VOLUME_VERIFY_FAILED` -40 with auto-healing for `-69863` / `-69888`)
- **`src/engine/CanaryProbeService.swift`**:
  - Per-mount 300s cache (`cacheByMount`).
  - Allocates **4096-byte page-aligned buffers** (`UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 4096)`) for `F_NOCACHE` DMA compatibility (`CANARY-02`).
  - Probes `<mount>/.disk_health_canary_<uid>` (or `ConfigManager.shared.configDir` when `targetMount == "/"` to avoid `/private/tmp` sticky-bit collisions, `CANARY-03`).
  - Performs in-place `open(O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600)`, `fcntl(F_NOCACHE, 1)` (with `EINVAL` retry fallback for FAT32/exFAT), `pwrite`, `fcntl(F_FULLFSYNC)` (with `fsync` fallback), `pread`, and `memcmp`. Self-heals orphaned `0400` canary files via `unlink()` retry (`UAT2-04`). Unlinks canary file on external `/Volumes/*` mounts after pass. Falls back to `opendir`/`readdir` on `EROFS`/`EACCES`.
- **`src/engine/VolumeVerifierService.swift`**:
  - Runs `/usr/sbin/diskutil verifyVolume <target>` asynchronously with a 180s `DispatchSourceTimer` watchdog.
  - Drains stdout/stderr pipe *before* `waitUntilExit()`.
  - Terminates grandchild process trees (`fsck_apfs`) on timeout via `terminateProcessAndChildren(pid:signal:)` (`/usr/bin/pkill -P <pid>` + `kill`).
  - Classifies `-69863` (insufficient privileges) and `-69888` (volume busy) as healthy `Skipped`, and timeouts as `Failed` (`VERIFY-01`).
- **`src/engine/SurfaceScannerService.swift`**:
  - Non-destructive direct read scanner (`O_RDONLY | O_NOFOLLOW | O_CLOEXEC` + `fcntl(fd, F_NOCACHE, 1)`, 4096B page-aligned buffer, `EINTR` retry) across 3 modes: `.quick` (120 files, 256 KB/file, 64 MB cap), `.standard` (2,000 files, 2 MB/file, 2 GB cap), `.full` (entire volume). Supports `SurfaceScanCancellationToken` and live ETA progress callbacks.
- **`src/engine/TelemetryHistoryStore.swift`**:
  - Bounded 180-point ring buffer (`TelemetryHistorySample`) per `driveKey` persisted to `~/.config/disk-health-monitor/history.json` (`0600`) with 60s sampling cadence. Computes rate-of-change metrics (`freeSpaceDropGBPerHour`, `terabytesWrittenLast24h`) and powers native SwiftUI historical trend sparklines.
- **`src/engine/ActionRuleEngine.swift`**:
  - Declarative `"When [Trigger] on [Drive Scope] for [Consecutive Polls] -> Do [Action]"` automation engine.
  - Evaluates 13 trigger metrics (specific issue codes, numeric thresholds, severity transitions, and rate-of-change triggers) across 6 drive scopes with per-rule poll hysteresis (`consecutivePollsRequired`) and cooldowns (`cooldownSeconds`).
  - Enforces hard safety guards (`ActionRuleEngine.isSystemProtectedMount` blocks destructive actions on `/`, `/System/*`, Recovery/Preboot/VM) and supports dry-run simulation (`simulateRule`).
  - Dispatches 12 actions asynchronously on a serial background queue with pipe-before-wait draining and process-tree watchdogs.
- **`src/diagnostics/ProcessIoInspector.swift`**:
  - Samples Darwin `DiskSampleProcessIoMetrics` across a configurable interval (`sampleTopProcesses(durationSeconds:limit:)` or delta against previous poll) to rank active processes by read/write disk throughput (`B/s`).
- **`src/engine/DiskHealthMonitor.swift`**:
  - Orchestrates `evaluateAllMonitoredDisks`, `evaluateHealth`, `TelemetryHistoryStore`, and `ActionRuleEngine`.
  - **Interval Latency (`RULE-01`)**: Tracks `DriveThroughputSample` (`bytesRead`, `bytesWritten`, `operationsRead`, `operationsWritten`, `totalTimeReadNs`, `totalTimeWriteNs`, `timestamp`) per `driveKey`. Computes interval latency $\Delta\text{timeNs} / \Delta\text{ops}$ when $\Delta\text{ops} \ge 50$.
  - **Session-Aware Baselines (`RULE-02`)**: Automatically re-baselines error/retry counters when counters decrease (system reboot or drive replug) and advances baselines upon alert dispatch.
  - **Alert Hysteresis & Cooldowns (`ALERT-01`)**: Tracks `consecutiveUnhealthyPolls` and `consecutiveHealthyPolls`. Defers single-poll transient warnings (`IO_LATENCY_WARNING`, `CANARY_HIGH_LATENCY`, `TEMP_RAPID_RISE`) until `consecutiveUnhealthyPolls >= 2`. Requires `consecutiveHealthyPolls >= 2` before firing recovery notifications, and holds cooldown keys for 900s across brief recoveries.
  - **Inter-Process State Locking (`STATE-02`)**: Acquires `flock(LOCK_EX)` on `state.lock` inside `saveStateLocked()` and gates writes on dirty state (`lastSavedState != state`). Read-only CLI flags pass `persistState: false`.
  - **Alert Script Sandbox (`MISSED-03`, `PROC-PIPE-01`)**: Verifies `ConfigManager.isSecureUserOwnedFile(atPath:)` before executing alert scripts, scrubs environment variables via `makeCleanAlertScriptEnvironment` (stripping `TELEGRAM_*`, `WEBHOOK_URL`, `SSH_AUTH_SOCK`), drains stdout/stderr pipes before `waitUntilExit()`, and enforces a 15s watchdog with `terminateProcessAndChildren`.
- **`src/diagnostics/DiagnosticExporter.swift`**:
  - Generates JSON bundles (`generateDiagnosticReport`) and standalone dark-mode HTML RMA reports (`exportDiagnosticReportHTML`) with multi-disk fleet overview tables.
  - **Reverse-Seek Log Tailer (`OPT-05`, `SYS2-01`)**: `readLastLogLines` seeks to `fileSize - 65537` (`maxTailBytes + 1`) and checks `buffer[0] != '\n'` when `offset > 0` to deterministically drop truncated leading UTF-8 lines.
- **`src/notifications/`**:
  - `MacOSNotifier.swift` (`UNUserNotificationCenter`, bundle guard `hasValidAppBundle`), `TelegramNotifier.swift` (HTML reports truncated to 4000 chars, token redaction), `WebhookNotifier.swift` (Discord/Slack/Mattermost/ntfy JSON payloads, URL path/query redaction).

### Layer 4: Presentation & CLI Entrypoint (`src/ui/`, `src/main.swift`)
- **`src/main.swift`**:
  - Validates CLI flags (exits `64` on unknown flags while ignoring `-psn_*`, `-NS*`, `-Apple*` LaunchServices args).
  - Re-executes into `DiskHealthMonitor.app/Contents/MacOS/DiskHealthMonitor` and detaches from terminal via `POSIX_SPAWN_SETSID` when launched in GUI mode.
- **`src/ui/AppDelegate.swift`**:
  - Manages `NSStatusItem` with cached SF Symbols (`statusSymbolCache`) and notch-safe title truncation ($\le 18$ chars).
  - Reads `publishedMultiSnapshot` and `publishedSnapshot` lock-free on `@MainActor`.
  - Filters system/Time Machine mount notifications via `shouldProcessVolumeNotification(volumePath:)`.
- **`src/ui/DashboardMenuView.swift`**:
  - 385pt SwiftUI popover with horizontal multi-disk pill switcher (`monitor.selectDashboardDrive(key:)`), capacity bar with APFS purgeable space, 2x2 telemetry grid, live I/O strip, and active issues list.
- **`src/ui/SettingsView.swift`, `SettingsViewModel.swift`, `SettingsComponents.swift` & `src/ui/tabs/*.swift`**:
  - 7 tabs (`820x700`): `0` `GeneralSettingsTab`, `1` `ThresholdsSettingsTab`, `2` `NotificationsSettingsTab`, `6` `AutomationRulesTab` (`⌘A`), `3` `SmartInspectorTab` (`⌘I`), `4` `StatisticsAndInsightsTab` (`⌘S`), `5` `DiagnosticsAndExportTab`.
  - Ephemeral `NSWindowDelegate` lifecycle (`windowWillClose` releases `contentViewController` and `window` to save 15–22 MB idle RSS, `OPT2-03`).

---

## 3. HARDENED INVARIANTS & CONCURRENCY HIERARCHY

### Acyclic Lock Order (Never Violate)
```text
Main Thread (@MainActor: reads publishedSnapshot / publishedMultiSnapshot / publishedActionLog lock-free)
  ├─> DiskHealthMonitor.snapshotLock (NSLock, leaf lock for currentSnapshot/currentMultiSnapshot/actionExecutionLog)
  ├─> SettingsViewModel.debounceLock (NSLock, leaf lock, released before SecretStore/ConfigManager)
  └─> DiskHealthMonitor.engineLock (NSRecursiveLock)
        ├─> ConfigManager.configLock (NSRecursiveLock)
        │     └─> SecretStore.lock (NSRecursiveLock)
        ├─> TelemetryHistoryStore.lock (NSLock, leaf lock)
        ├─> ProcessIoInspector.lock (NSLock, leaf lock)
        ├─> CanaryProbeService.lock (NSLock)
        │     └─> CanaryProbeService.mountExecutionLocks (NSLock per mount)
        ├─> ConfigManager.logLock (NSLock)
        └─> DiskHealthBridge.sStaticCacheMutex (pthread_mutex_t)
```
1. **Never acquire `engineLock` on the main UI thread**: UI views and `AppDelegate` read `monitor.publishedMultiSnapshot` and `monitor.publishedSnapshot` lock-free or read snapshot copies via leaf `snapshotLock`. `selectDashboardDrive(key:)` updates `@Published` properties immediately on the main thread and syncs internal keys via leaf `snapshotLock`.
2. **Never call `DiskHealthMonitor` while holding `ConfigManager.configLock`**: `ConfigManager` always unlocks `configLock` *before* calling `notifyObjectWillChangeOnMain()`.
3. **Zero Unprompted Keychain Popups**: Never call `SecretStore.getSecret` or `setSecret` with `allowInteractiveKeychain: true` outside `SettingsViewModel.onboardCredentialsToKeychainAction()`.
4. **Strict POSIX `0600` File Creation**: All state, config, secret, log, and exported report files must use `AtomicFileWriter.writeRestricted(..., permissions: 0o600)` or `open(..., O_CREAT | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)`.

---

## 4. EVOLUTION & AUDIT CHRONOLOGY (`v1.0.0` $\rightarrow$ `v2.8.0`)

- **v1.0.0 – v2.1.0 (Rounds 1–8)**: Initial C11 IOKit/NVMe SMART bridge, 12-point health engine, Menu Bar UI, LaunchAgent installer, `SingleInstanceLock` (`O_NOFOLLOW`), Universal Binary (`arm64` + `x86_64`) packager, and GitHub Actions CI.
- **v2.2.0 – v2.3.0 (Rounds 9–12)**: Added multi-tier `F_NOCACHE` surface scanner (`quick`, `standard`, `full`), hardware S.M.A.R.T. inspector (`⌘I`), SSD endurance forecasting, APFS purgeable space accounting, universal webhooks, standalone HTML RMA reports (`⌘H`), `POSIX_SPAWN_SETSID` terminal detachment, 4-layer modular decomposition (25 files), opt-in Keychain state machine (`SecretStore`), `AtomicFileWriter`, and Round 12 pipe-drain/watchdog hardening (15 C tests + 37 Swift tests).
- **v2.4.0 (Pass 1 & Pass 2 Argon Audits)**: Added simultaneous multi-disk monitoring (`monitorAllDisks`, `monitoredTargets`, `--all`), `MultiDiskHealthSnapshot`, 6th Settings tab (`StatisticsAndInsightsTab`, `⌘S`), 32-entry C static registry cache (`sStaticCache`), in-place sector-aligned canary probes, `0400` orphan self-healing, reverse-seek UTF-8 boundary-safe log tailing, and grandchild subprocess termination (`pkill -P`) (15 C tests + 40 Swift tests).
- **v2.5.0 (Adversarial Security & Signal Quality Hardening)**: Fixed cwd `.env` injection (`SEC-01`, `isSecureUserOwnedFile`), pinned `stateDir` to `configDir` (`STATE-01`), added `state.lock` inter-process `flock` and read-only CLI non-mutation (`STATE-02`), alert poll/value hysteresis (`ALERT-01`), interval latency $\Delta\text{time}/\Delta\text{ops}$ (`RULE-01`), session-aware error re-baselining (`RULE-02`), natural read-only FS exemptions (`RULE-03`), duplicate/placeholder serial composite keys (`RULE-05`), and alert script environment scrubbing (`MISSED-03`).
- **v2.6.0 (Build 9 — Full-Timeline Production Hardening)**: Guarded non-USB link speeds against PCIe Gen `1..5` enum collisions (`BRIDGE-02`), filtered virtual `.dmg` disk images and expanded `sStaticCache` to 64 entries (`BRIDGE-04`), unified `DiskHealthSnapshot.isPlaceholderSerial` and composite `snap.driveKey` across `resetBaselines()` and `runVolumeVerification()` (`STATE-03`), added automatic token/webhook regex redaction + 2s burst deduplication in `ConfigManager.log` (`LOG-01`), upgraded canary probe to 4096B page-aligned buffers with `F_FULLFSYNC` (`CANARY-02`), gated APFS purgeable space lookup (`PERF-01`), scoped `HOST_THERMAL_CRITICAL` to internal drives (`RULE-06`) and internal Apple SSD error log delta $\ge 5$ (`RULE-07`), exposed multi-disk checklist in `GeneralSettingsTab` (`UI-03`), and added `NSLocalNetworkUsageDescription` to `Info.plist` (`BUILD-01`). Certified with 16 C tests + 48 Swift tests.
- **v2.7.0 (Build 10 — Argon Architecture & Concurrency Hardening)**: Guarded CoreFoundation in `DiskHealthBridge.h` for pure C11 cross-platform portability (`C11-PORT`), added fast registry ID / partition prefix mount resolution and raw disk caching in `sStaticCache` (`BRIDGE-05`), prioritized physical devices over virtual `.dmg` images in `DiskListAllDevices` (`BRIDGE-06`), added leaf `snapshotLock` decoupling `currentSnapshot`/`currentMultiSnapshot` from `engineLock` (`CONC-01`), disambiguated cloned bridge serials via `customDriveKey` (`STATE-04`), added per-mount canary serialization in `CanaryProbeService` (`CANARY-04`), de-inverted `debounceLock` in `SettingsViewModel` and offloaded diagnostic export I/O (`UI-04`), applied `AtomicFileWriter.writeRestricted` (`0600`) to LaunchAgent generator (`SEC-03`), pre-compiled log redaction regexes and added `EINTR`-safe log write loop (`LOG-02`), and added side-effect-free diagnostic exports (`persistState: false`). Certified with 16 C tests + 49 Swift tests + 5 CLI integration stages passing.
- **v2.8.0 (Build 11 — Declarative Rule-Based Automation Engine, Process I/O Culprit Detector & Historical Sparklines)**: Added `ActionRuleEngine` (`When [Trigger] on [Drive Scope] for [Consecutive Polls] -> Do [Action]`) supporting 13 trigger metrics, 6 drive scopes, poll hysteresis, per-rule cooldowns, boot/system volume safety guards (`isSystemProtectedMount`), dry-run mode, 5 curated presets, and 12 built-in actions (`safeUnmountDrive`, `safeEjectDrive`, `remountReadOnly`, `startTimeMachineBackup`, `thinApfsSnapshots`, `captureTopIoProcesses`, `runMacShortcut`, etc.); added Darwin `<libproc.h>` `DiskSampleProcessIoMetrics` and `ProcessIoInspector` (`--top-io`); added `TelemetryHistoryStore` (`history.json`, 180-point ring buffer, rate-of-change triggers, and SwiftUI trend sparklines in `StatisticsAndInsightsTab`); added USB bus power (`usbCurrentAvailableMa`, `usbCurrentRequiredMa`) and PCIe/TB lane width (`linkWidthLanes`) in `DiskHealthBridge.c` and `SmartInspectorTab`; added 7th Settings tab `AutomationRulesTab` (`⌘A`) and CLI flags `--list-rules`, `--simulate-rule`, and `--top-io`. Certified with **17 C tests + 52 Swift tests + 5 CLI integration stages passing**.

---

## 5. VERIFICATION & RUNBOOK COMMANDS

### Build, Test & Package
```bash
# 1. Compile DiskHealthMonitor.app and ./disk-health CLI symlink
./build_and_install.sh

# 2. Run full 5-stage verification suite (17 C tests + 52 Swift tests + CLI + Exporters + Bundle)
./build_and_install.sh --test

# 3. Run C11 / IOKit Bridge unit tests standalone (17 tests)
mkdir -p .build-cache
clang -O2 -Wall -Wextra -c src/bridge/DiskHealthBridge.c -o .build-cache/DiskHealthBridge_test.o
clang -O2 -Wall -Wextra -Isrc/bridge -I. tests/test_disk_health_bridge.c .build-cache/DiskHealthBridge_test.o -framework IOKit -framework CoreFoundation -o .build-cache/test_disk_health_bridge
./.build-cache/test_disk_health_bridge

# 4. Build Universal Binary (arm64 + x86_64) release DMGs, ZIPs, and SHA256SUMS in dist/
./build_and_install.sh --package

# 5. Regenerate AppIcon.png and AppIcon.icns from CoreGraphics vector script
./build_and_install.sh --regenerate-icon
```

### LaunchAgent & CLI Management
```bash
# Install / Uninstall LaunchAgent (~/Library/LaunchAgents/io.github.disk-health-monitor.plist)
./build_and_install.sh --install-service
./build_and_install.sh --uninstall-service

# Install CLI symlink to /usr/local/bin/disk-health
./build_and_install.sh --install-cli
```

### CLI Flags Cheat Sheet
```bash
./disk-health --status                     # Human-readable health report (read-only)
./disk-health --status --all               # Fleet health report across all physical disks
./disk-health --json [--all]               # Pretty-printed JSON telemetry snapshot
./disk-health --list-disks                 # Enumerate all block devices, buses, and SMART status
./disk-health --check [--all] [--deep]     # Daemon check cycle (persists state & dispatches alerts)
./disk-health --watch-mounts               # Mount-triggered evaluation cycle
./disk-health --surface-scan [quick|standard|full] # Direct F_NOCACHE physical media read scan
./disk-health --verify [--notify]          # Run diskutil verifyVolume with 180s watchdog
./disk-health --test-alert-script          # Validate & run custom alert script with 15s watchdog
./disk-health --export-diagnostics [path]  # Save sanitized JSON diagnostic bundle
./disk-health --export-html [path]         # Save standalone HTML health & RMA report
./disk-health --export-config [--unmasked] # Print sanitized (or unmasked) config.json
./disk-health --import-config <file>       # Import configuration JSON profile
./disk-health --list-rules                 # List configured automation rules & recent audit log
./disk-health --simulate-rule [id|index]   # Dry-run simulate an automation rule
./disk-health --top-io                     # Sample top disk I/O processes over 1.2s via libproc
./disk-health --volume <path>              # Override target mount path (e.g. / or /Volumes/T7)
./disk-health --device <query>             # Override target BSD name (disk4), model, or serial
./disk-health --menubar                    # Launch persistent Menu Bar GUI agent
./disk-health --version | --help           # Version & usage manual
```

---

## 6. KNOWN PITFALLS & FUTURE ROADMAP

### What Must NEVER Be Done (Anti-Patterns)
- **DO NOT** call `monitor.currentSnapshot`, `monitor.currentMultiSnapshot`, or `evaluateAllMonitoredDisks` synchronously on the main thread (`@MainActor` / SwiftUI `body` / `NSMenuDelegate.menuWillOpen`). Always read `monitor.publishedMultiSnapshot` and `monitor.publishedSnapshot`.
- **DO NOT** use `Data.write(to:options:.atomic)` for config, state, secrets, or reports. Always use `AtomicFileWriter.writeRestricted(data:toPath:permissions: 0o600)`.
- **DO NOT** remove the APFS subtree pruning check (`AppleAPFSContainerScheme`, `AppleAPFSContainer`, `AppleAPFSMedia`, `AppleAPFSVolume`) in `DiskHealthBridge.c`.
- **DO NOT** restore `bsdName` from `sStaticCache` on cache hits in `DiskHealthBridge.c`; live `IOMedia` child traversal is required to detect BSD device renumbering after hot-replug.
- **DO NOT** add Swift 5.9+ macro attributes (`@Observable`) or external packages; the project must compile with standalone `swiftc` and `clang`.

### Planned Roadmap (`v3.0.0` Argon Recommendations)
1. **Lock-Split Bounded Parallel Probing (`CONC-03`)**: Decouple per-drive `statfs` and `CanaryProbeService` I/O from `engineLock` using a bounded worker pool (max concurrency 4) with a 3-second per-drive circuit breaker so a dying external USB enclosure in uninterruptible kernel sleep (`D` state) cannot stall fleet polling.
2. **USB UASP / SAT Pass-Through (`SCSITaskUserClient`)**: Secondary probe in `DiskHealthBridge.c` issuing non-destructive SAT ATA PASS-THROUGH (`0x85`) / NVMe Admin pass-through CDBs for external USB enclosures (`RTL9210`, `ASM2362`, `JMS583`) that hide `IONVMeSMARTUserClient`.
3. **Compact Historical Telemetry (`HIST-01`)**: Append rate-limited 5-minute samples to `history/<driveKey>.jsonl` (90-day retention) to power calendar-based endurance forecasting and historical thermal/latency charts in `StatisticsAndInsightsTab`.
4. **Process-Group Subprocess Isolation**: Spawn `diskutil` and alert scripts with `POSIX_SPAWN_SETPGROUP` and signal `-pgid` to eliminate any theoretical PID-recycling window in `pkill -P`.

---

> [!IMPORTANT]
> **REMINDER**: Keep `AGENTS.md` synchronized with every code, test, CLI, or architectural change. Run `./build_and_install.sh --test` before concluding any task.
