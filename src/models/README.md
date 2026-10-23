# Domain Models & Telemetry Schema (`src/models/`)

This directory defines the strongly typed, `Codable` Swift data structures representing drive telemetry snapshots, health anomalies, SSD wear and endurance projections, per-drive state persistence, and thread-safe date formatters.

---

## Files

### [`HealthModels.swift`](HealthModels.swift)

#### 1. Core Health Enums & Issues
- **`HealthSeverity`**: Operational tiers: `.healthy` (rank 0), `.warning` (rank 1), `.critical` (rank 2).
- **`HealthIssue`**: Encapsulates an anomaly with machine-readable `code` (e.g., `TEMP_WARNING`, `SPARE_CRITICAL`, `CANARY_IO_FAILED`), human-readable `title`, detailed telemetry `detail`, and `severity`.

#### 2. `DiskHealthSnapshot`
Point-in-time telemetry snapshot serialized to `logs/latest_status.json` and returned via `--json`:
- **System**: `timestamp`, `formattedTime`, `formattedShortTime`, `overallSeverity`, `healthScore`, `issues`.
- **Filesystem & Capacity**: `mountPoint`, `filesystemType`, `totalBytes`, `freeBytes`, `purgeableBytes` (opportunistic APFS capacity), `usedBytes`, `usedPercent`, `isReadOnly`, `subpathsStatus`.
- **Hardware & Bus**: `vendorName`, `productName`, `bsdName`, `serialNumber`, `interconnectType`, `protocolType`, `isInternal`, `linkSpeedBps`, `linkSpeedFormatted`.
- **NVMe S.M.A.R.T.**: `smartValid`, `criticalWarning`, `temperatureCelsius`, `temperatureKelvin`, `peakTemperatureCelsius`, `availableSpare`, `availableSpareThreshold`, `percentageUsed`, `lifeRemainingPercent`, `dataUnitsRead`, `dataUnitsWritten`, `totalTerabytesRead`, `totalTerabytesWritten`, `powerCycles`, `powerOnHours`, `unsafeShutdowns`, `mediaErrors`, `errorInfoLogEntries`.
- **Storage Driver Stats**: `statsValid`, `sessionBytesRead`, `sessionBytesWritten`, `operationsRead`, `operationsWritten`, `errorsRead`, `errorsWritten`, `avgReadLatencyMs`, `avgWriteLatencyMs`, `readThroughputMBps`, `writeThroughputMBps`.
- **Active Canary & Verification**: `canaryOk`, `canaryLatencyMs`, `lastVerifyResult`, `lastVerifyOk`.

#### 3. Computed SSD Endurance & Lifespan Projections
- **`dailyTerabytesWritten`**: Calculates daily write burn rate:
  $$\text{Burn Rate} = \frac{\text{Total TBW}}{\max(1, \text{POH} / 24)} \quad (\text{TB/day})$$
- **`estimatedRemainingLifeFormatted`**: Projects operational longevity from accumulated wear percentage and Power-On Hours (e.g., `"> 10 Years (0% Wear)"`, `"~4.2 Years remaining"`, or `"Depleted"`).

#### 4. Persistent State Scoping (`DiskPersistentState` & `DriveBaselineState`)
Stored at `logs/state.json`:
- **`DriveBaselineState`**: Scoped by drive key (`serialNumber` or `bsdName`), tracking baseline counters for unsafe shutdowns, media errors, driver errors/retries, peak temperature, and per-drive `lastOverallSeverity`.
- **`DiskPersistentState`**: Manages global settings, active target, and scoped alert cooldowns (`lastAlertTimestampByCode`).

#### 5. Thread-Safe Date Formatters (`SynchronizedDateFormatter`)
Wraps `DateFormatter` with an internal `NSLock` and `en_US_POSIX` locale to prevent concurrent mutation crashes and formatting drift across locale boundaries:
- `isoTimestampFormatter`: `yyyy-MM-dd HH:mm:ss`
- `shortTimeFormatter`: `HH:mm:ss`
- `shortMonthDateFormatter`: `MMM d, HH:mm`

#### 6. Fleet Aggregation (`MultiDiskHealthSnapshot`)
Aggregates simultaneous per-drive `DiskHealthSnapshot` evaluations with fleet-wide `overallSeverity`, `worstHealthScore`, `averageHealthScore`, `totalIssuesCount`, and deterministic `primarySnapshot` selection (highest severity, tie-broken by lowest health score).

---

### [`DiskHealthError.swift`](DiskHealthError.swift)
Defines the structured `DiskHealthError` (`LocalizedError`, `Equatable`, `Sendable`) enum covering hardware discovery, mount inspection, canary probes, surface scans, volume verification, configuration validation, Keychain status codes, atomic file writes, and alert script execution.
