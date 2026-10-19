# Domain Models & Formatters (`src/models/`)

This directory defines the strongly typed, `Codable` Swift data models that represent drive telemetry snapshots, health anomalies, per-drive persistent state, and thread-safe POSIX date formatters.

---

## Files

### [`HealthModels.swift`](HealthModels.swift)

1. **`HealthSeverity` (`String`, `Codable`)**:
   - Represents the three operational health tiers:
     - `.healthy` (`"HEALTHY"`, rank `0`): All hardware, filesystem, and driver checks passed.
     - `.warning` (`"WARNING"`, rank `1`): Non-destructive degradation detected (e.g., elevated temperature, downgraded USB bus speed, high wear, or low free space).
     - `.critical` (`"CRITICAL"`, rank `2`): Immediate risk of data loss or hardware failure (e.g., SMART failure, media errors, driver I/O errors, read-only volume, or canary write failure).

2. **`HealthIssue` (`Codable`, `Identifiable`)**:
   - Encapsulates a single detected anomaly with:
     - `severity`: `HealthSeverity`
     - `code`: Machine-readable rule identifier (e.g., `"TEMP_WARNING"`, `"USB_DOWNGRADED"`, `"NVME_WEAR_HIGH"`, `"CANARY_IO_ERROR"`, `"IO_LATENCY_CRITICAL"`, `"HOST_THERMAL_CRITICAL"`).
     - `title`: Concise human-readable summary.
     - `detail`: Actionable explanation with measured telemetry and configured thresholds.

3. **`DiskHealthSnapshot` (`Codable`)**:
   - Complete point-in-time record of a health evaluation run, serialized to `logs/latest_status.json` and printed via `--json`:
     - System metadata (`timestamp`, `formattedTime`, `formattedShortTime`, `healthScore`, `overallSeverity`, `issues`).
     - Volume & filesystem metrics (`isMounted`, `mountPoint`, `filesystemType`, `isReadOnly`, `totalBytes`, `freeBytes`, `usedBytes`, `usedPercent`, `subpathsStatus`, `canaryOk`, `canaryLatencyMs`).
     - Hardware & bus metrics (`hardwareFound`, `vendorName`, `productName`, `productRevision`, `bsdName`, `serialNumber`, `usbSerialNumber`, `interconnectType`, `protocolType`, `isInternal`, `isRemovable`, `linkSpeedBps`, `linkSpeedFormatted`).
     - NVMe SMART metrics (`smartValid`, `criticalWarning`, `temperatureCelsius`, `temperatureKelvin`, `availableSpare`, `availableSpareThreshold`, `percentageUsed`, `lifeRemainingPercent`, `totalTerabytesRead`, `totalTerabytesWritten`, `powerCycles`, `powerOnHours`, `unsafeShutdowns`, `mediaErrors`, `errorInfoLogEntries`).
     - Storage driver statistics (`statsValid`, `sessionBytesRead`, `sessionBytesWritten`, `operationsRead`, `operationsWritten`, `errorsRead`, `errorsWritten`, `retriesRead`, `retriesWritten`, `avgReadLatencyMs`, `avgWriteLatencyMs`, `readThroughputMBps`, `writeThroughputMBps`).
     - Volume verification state (`lastVerifyResult`, `lastVerifyOk`).

4. **`DriveBaselineState` & `DiskPersistentState` (`Codable`)**:
   - Stored at `logs/state.json` to maintain isolated historical state scoped by physical drive identifier (`serialNumber` or `bsdName`):
     - `driveStates`: Map of drive key to `DriveBaselineState`, isolating baselines for unsafe shutdowns, media errors, error log entries, driver I/O errors/retries, peak temperature, and volume verification status.
     - `lastAlertTimestamp` & `lastAlertSeverity`: Per-drive alert cooldown tracker (`alertCooldownSeconds`).
     - `lastDailyDigestTimestamp` & `dailyDigestEnabled`: Controls scheduled daily summary Telegram dispatches.

5. **Thread-Safe Date Formatters (`SynchronizedDateFormatter`)**:
   - Thread-safe date formatting wrappers using `NSLock` and `en_US_POSIX` locale to prevent concurrent mutation crashes and avoid 12-hour/24-hour locale formatting anomalies:
     - `isoDateFormatter`: ISO-8601 formatting.
     - `shortTimeFormatter`: `HH:mm:ss` timestamp format.
     - `shortMonthDateFormatter`: `MMM d, HH:mm` timestamp format.
