# Health Evaluation Engine (`src/engine/`)

This directory contains the central monitoring engine (`DiskHealthMonitor`), lock-split parallel prober (`ParallelDriveProber`), persistent state store (`PersistentStateStore`), 15-rule evaluation pipeline (`HealthRules`), declarative automation (`ActionRuleEngine`), 90-day telemetry archive (`TelemetryHistoryStore`), power management (`PowerManagementService`), APFS snapshot service (`ApfsSnapshotService`), active canary probe (`CanaryProbeService`), physical surface scanner (`SurfaceScannerService`), and volume verifier (`VolumeVerifierService`).

---

## Files

### [`DiskHealthMonitor.swift`](DiskHealthMonitor.swift)

#### 1. Lock-Split Concurrency & Sleep/Wake Lifecycle
- Splits `evaluateAllMonitoredDisks` into unlocked Phase A (`collectPhaseATelemetry`: hardware discovery + `ParallelDriveProber`) and locked Phase B (`evaluatePreparedTargetLocked` under `engineLock`), eliminating VFS stall contention across concurrent readers.
- Observes `NSWorkspace.willSleepNotification` and `didWakeNotification`: pauses background evaluation during sleep and applies an 8-second wake settle grace period before querying external storage buses.

### [`PersistentStateStore.swift`](PersistentStateStore.swift)
- Encapsulates `state.json` load/migration, `flock(LOCK_EX)` dirty-gated `0600` saves (`state.lock`), `latest_status.json` snapshots, per-drive baseline synchronization, and `resetBaselines()`.

### [`ParallelDriveProber.swift`](ParallelDriveProber.swift)
- Runs a bounded 4-worker `OperationQueue` with a 3.0s circuit breaker per mount, `inFlightMounts` de-duplication, Dark Wake deferral, APFS container enumeration, required subpath checks, internal/`/` quarantine exemption, and 120s auto-recovery quarantine TTL.

### [`HealthRules.swift`](HealthRules.swift)
- 15 pure functional `HealthRule` structs (`StandardHealthRulePipeline.defaultRules`): rules 1–12 plus `BusSignalIntegrityRule` (`BUS_PHY_ERRORS`, deferring nil baseline capture), `ApfsSwapPressureRule` (`APFS_SWAP_PRESSURE`), and `ControllerQuarantineRule` (`IO_CONTROLLER_UNRESPONSIVE`, -55). Evaluates HID die temperature via `smartValid || temperatureCelsius > 0` in `ThermalAndSpikeRule`.

### [`ActionRuleEngine.swift`](ActionRuleEngine.swift), [`TelemetryHistoryStore.swift`](TelemetryHistoryStore.swift), [`PowerManagementService.swift`](PowerManagementService.swift) & [`ApfsSnapshotService.swift`](ApfsSnapshotService.swift)
- **`ActionRuleEngine`**: Evaluates declarative `When -> Do` rules (including event-driven `.systemWillSleep`) with boot-volume protections, dry-run mode, and `SubprocessRunner`-isolated action execution.
- **`TelemetryHistoryStore`**: 180-point ring buffer (`history.json`), isolated `<customFilePath>.archive` or `configDir/history/<driveKey>.jsonl` 90-day archives with OLS wear regression (`computeRollingForecasts`) and 512KB/24h gated pruning.
- **`PowerManagementService`**: Monitors `kIOMessageSystemWillSleep` for external pre-sleep unmounts and wraps long operations in `IOPMAssertion`.
- **`ApfsSnapshotService`**: Lists and thins APFS local snapshots via `tmutil` with path traversal and byte clamping guards.

#### 2. Active Canary I/O Probe (`CanaryProbeService.swift`)
- On mounted writable volumes, writes a 4096-byte page-aligned payload to `<mountPath>/.disk_health_canary_<uid>` in-place with POSIX flags `O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC`, permissions `0600`, and `fcntl(fd, F_NOCACHE, 1)`.
- Flushes volatile drive cache to physical media via `fcntl(fd, F_FULLFSYNC)` (with automatic fallback to `fsync(2)`), verifies data integrity on read-back, unlinks external mount probes, and measures round-trip latency (`canaryLatencyMs`).
- Features a 50 ms settle retry on transient external bus hiccups and directs probes to `~/.config/disk-health-monitor` when monitoring the sealed APFS root (`/`).

#### 3. Multi-Tier Physical Surface Scanner (`runSurfaceReadScan`)
Performs non-destructive direct media read verification with unbuffered I/O:
- **`F_NOCACHE` Bypass**: Issues `fcntl(fd, F_NOCACHE, 1)` on each opened file to bypass the macOS Unified Buffer Cache, forcing physical media read operations.
- **Three Operational Modes**:
  - `quick`: Top 200 files (rapid media confidence check).
  - `standard`: Up to 2,000 files or 10 GB total read volume.
  - `full`: Exhaustive filesystem tree walk.
- **Progress Telemetry**: Reports real-time throughput ($\text{MB/s}$), scanned byte/file counts, read errors, ETA, and supports cancellation via `SurfaceScanCancellationToken`.

#### 4. Filesystem Verification & Scheduling
- Executes `/usr/sbin/diskutil verifyVolume <target>` with a 180-second watchdog timer, non-blocking pipe drainage, and two-stage process termination (`SIGTERM` followed by `SIGKILL`).
- Distinguishes genuine corruption from unprivileged execution (`-69863`) or busy unmount states (`-69888`), preventing false-positive alerts.
- Supports periodic scheduling via `scheduledVerifyIntervalHours` (e.g., every 6h, 12h, 24h, 48h, or weekly).

#### 5. 12-Rule Evaluation Pipeline (`evaluateHealth`)

| # | Rule Category | Trigger Condition | Severity | Issue Codes |
| :--- | :--- | :--- | :--- | :--- |
| **1** | **Mount & Subpaths** | Volume unmounted, device missing, or required subpaths absent | `CRITICAL` | `HW_DISCONNECTED`, `VOLUME_UNMOUNTED`, `REQUIRED_PATH_MISSING` |
| **2** | **Hardware S.M.A.R.T.** | Critical Warning bitmask `!= 0` | `CRITICAL` | `SMART_CRITICAL_WARNING` |
| **3** | **Available Spare** | Spare `< 25%` (`WARNING`) or `<= threshold` / `< 10%` (`CRITICAL`) | `WARNING` / `CRITICAL` | `SPARE_WARNING`, `SPARE_CRITICAL` |
| **4** | **SSD Wear Level** | Wear `>= 80%` (`WARNING`) or `>= 95%` (`CRITICAL`) | `WARNING` / `CRITICAL` | `WEAR_WARNING`, `WEAR_CRITICAL` |
| **5** | **Drive Temperature** | Temp `>= warning` or `>= critical`; rapid spike detected | `WARNING` / `CRITICAL` | `TEMP_WARNING`, `TEMP_CRITICAL`, `TEMP_RAPID_RISE` |
| **6** | **Host Thermal State** | Host system thermal state in `.critical` | `WARNING` | `HOST_THERMAL_CRITICAL` |
| **7** | **Media & Kernel Errors** | Delta in media errors, error logs, or driver errors/retries | `WARNING` / `CRITICAL` | `MEDIA_ERRORS`, `ERROR_LOG_INCREASED`, `IO_DRIVER_ERRORS`, `IO_DRIVER_RETRIES` |
| **8** | **I/O Latency Spikes** | Driver read/write latency exceeds threshold (`> 50 ms` warn, `> 200 ms` crit) | `WARNING` / `CRITICAL` | `IO_LATENCY_WARNING`, `IO_LATENCY_CRITICAL` |
| **9** | **Bus Link Speed** | External connection negotiated below expected speed | `WARNING` | `USB_LINK_DEGRADED` |
| **10** | **Unsafe Shutdowns** | Counter incremented relative to persisted baseline | `WARNING` | `NEW_UNSAFE_SHUTDOWN` |
| **11** | **Capacity & Free Space** | Used `%` above ceiling or free space below floor | `WARNING` / `CRITICAL` | `DISK_SPACE_WARNING`, `DISK_SPACE_CRITICAL` |
| **12** | **Canary & Verification** | Volume read-only, canary write failure, or `verifyVolume` error | `WARNING` / `CRITICAL` | `VOLUME_READONLY`, `CANARY_IO_FAILED`, `CANARY_HIGH_LATENCY`, `VOLUME_VERIFY_FAILED` |

#### 6. Stateful Cooldowns & Recovery
- Maintains scoped alert timestamps (`"<driveKey>:<issueCode>"`) in `logs/state.json`.
- Suppresses repetitive alerts within `alertCooldownSeconds`.
- Dispatches a recovery notification (`RECOVERED — HEALTHY`) when all issues resolve, resetting alert cooldowns for that drive.
