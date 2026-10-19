# Domain Models & Formatters (`src/models/`)

This directory defines the strongly typed, `Codable` Swift data models that represent drive telemetry snapshots, health anomalies, persistent cross-session state, and thread-safe POSIX date formatters.

---

## Files

### [`HealthModels.swift`](HealthModels.swift)

1. **`HealthSeverity` (`String`, `Codable`, `Comparable`)**:
   - Represents the three operational health tiers:
     - `.healthy` (`"HEALTHY"`): All 12 hardware and filesystem checks passed.
     - `.warning` (`"WARNING"`): Non-destructive degradation detected (e.g., elevated temperature, downgraded USB bus speed, high wear, or low free space).
     - `.critical` (`"CRITICAL"`): Immediate risk of data loss or hardware failure (e.g., SMART failure, media errors, kernel I/O errors, read-only volume, or canary write failure).
   - Implements `Comparable` so the engine can aggregate multiple issues using `max()`.

2. **`HealthIssue` (`Codable`)**:
   - Encapsulates a single detected anomaly with:
     - `severity`: `HealthSeverity`
     - `code`: Machine-readable rule identifier (e.g., `"TEMP_WARNING"`, `"USB_DOWNGRADED"`, `"NVMe_WEAR_HIGH"`, `"CANARY_IO_ERROR"`).
     - `title`: Concise summary displayed in notifications and the menu bar card.
     - `details`: Actionable explanation with measured values and configured thresholds.

3. **`DiskHealthSnapshot` (`Codable`)**:
   - Complete point-in-time record of a health check run, serialized to `logs/latest_status.json` and printed via `--json`:
     - Timestamp metadata (`timestamp`, `shortTime`, `hostname`).
     - Volume and filesystem metrics (`volumeMounted`, `mountPath`, `filesystemType`, `totalBytes`, `freeBytes`, `usedPercent`, `canaryWriteOK`, `canaryLatencyMs`, `fsckVerifyOK`).
     - Hardware and I/O metrics (`deviceFound`, `bsdName`, `vendor`, `product`, `serial`, `transportProtocol`, `transportSpeed`, `usbSpeedCode`, `bytesRead`, `bytesWritten`, `readOperations`, `writeOperations`, `readErrors`, `writeErrors`, `readLatencyMs`, `writeLatencyMs`).
     - NVMe SMART metrics (`smartSupported`, `smartStatus`, `temperatureCelsius`, `availableSparePercent`, `percentageUsed`, `dataUnitsReadBytes`, `dataUnitsWrittenBytes`, `powerCycles`, `powerOnHours`, `unsafeShutdowns`, `mediaErrors`).
     - Evaluation result (`overallSeverity`, `issues`).

4. **`DiskPersistentState` (`Codable`)**:
   - Stored at `logs/state.json` to track historical deltas across daemon runs:
     - `lastSeverity`: Used to detect state transitions (e.g., `WARNING -> HEALTHY` recovery notifications).
     - `lastAlertEpochByCode`: Enforces per-issue alert cooldown windows (`alertCooldownMinutes`).
     - `lastReadErrors`, `lastWriteErrors`, `lastUnsafeShutdowns`, `lastMediaErrors`: Enables delta comparison so only newly incremented hardware counters trigger fresh alerts.

5. **Thread-Safe Date Formatters (`DateFormatters`)**:
   - Provides `iso8601` (`ISO8601DateFormatter`) and `shortTimeFormatter` (`HH:mm:ss` using `Locale(identifier: "en_US_POSIX")`) protected by an `NSLock` to guarantee consistent formatting regardless of the user's 12-hour/24-hour system locale settings.
