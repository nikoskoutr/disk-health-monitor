# Health Evaluation Engine (`src/engine/`)

This directory contains the core hardware and filesystem evaluation engine (`DiskHealthMonitor`) that orchestrates telemetry collection, active canary write testing, optional `diskutil verifyVolume` checks, the 12-rule health evaluation pipeline, state persistence, and alert cooldown management.

---

## Files

### [`DiskHealthMonitor.swift`](DiskHealthMonitor.swift)

#### 1. Concurrency & Synchronization
- Uses a dedicated serial dispatch queue (`com.universal.disk-health.state-queue`) to serialize reads and writes to `logs/state.json` and `logs/latest_status.json`, preventing race conditions when manual UI refreshes overlap with scheduled timer checks.

#### 2. Active Canary I/O Probe (`performCanaryProbe`)
- For mounted writable volumes, writes a small timestamped verification payload to `<mountPath>/.disk_health_canary`, forces an `fsync()` to physical media, reads the payload back to verify byte integrity, removes the temporary file, and measures total round-trip latency in milliseconds (`canaryLatencyMs`).
- Respects read-only system roots (such as macOS's sealed APFS snapshot on `/`) by skipping the write probe when `isReadOnly` is true on `/`.

#### 3. Deep Filesystem Verification (`runDiskutilVerify`)
- When invoked with `--deep` (or **"Run Deep Check (`verifyVolume`)"** in the UI), executes `/usr/sbin/diskutil verifyVolume <mountPath>` with a 90-second watchdog timeout to prevent hung I/O from blocking the daemon indefinitely.

#### 4. The 12 Health Evaluation Rules (`collectSnapshot`)

| # | Rule Category | Trigger Condition | Severity | Issue Code |
| :--- | :--- | :--- | :--- | :--- |
| 1 | **Hardware Presence** | Target volume unmounted & BSD device absent from IOKit | `WARNING` | `VOLUME_UNMOUNTED` |
| 2 | **Ghost Device** | Hardware device attached in IOKit, but filesystem failed to mount | `WARNING` | `VOLUME_NOT_MOUNTED_HARDWARE_PRESENT` |
| 3 | **USB Bus Negotiation** | External USB drive negotiated at USB 2.0 (`<= 480 Mbps`) instead of SuperSpeed (`5/10/20 Gbps`) | `WARNING` | `USB_DOWNGRADED` |
| 4 | **SMART Status** | Hardware SMART status reports anything other than `Verified` / `Not Supported` | `CRITICAL` | `SMART_FAILURE` |
| 5 | **NVMe Spare & Media** | `nvmeCriticalWarning != 0`, `mediaErrors > 0`, or `availableSpare < threshold` | `CRITICAL` | `NVME_CRITICAL_WARNING` / `NVME_MEDIA_ERRORS` / `NVME_SPARE_LOW` |
| 6 | **NVMe Wear Level** | `percentageUsed >= 90%` (`WARNING`) or `>= 100%` (`CRITICAL`) | `WARNING` / `CRITICAL` | `NVME_WEAR_HIGH` / `NVME_WEAR_CRITICAL` |
| 7 | **Drive Temperature** | `temperatureCelsius >= tempWarningCelsius` or `>= tempCriticalCelsius` | `WARNING` / `CRITICAL` | `TEMP_WARNING` / `TEMP_CRITICAL` |
| 8 | **Host Thermal State** | `ProcessInfo.processInfo.thermalState == .critical` | `WARNING` | `HOST_THERMAL_CRITICAL` |
| 9 | **Kernel I/O Errors** | Non-zero `readErrors` or `writeErrors` reported by `IOBlockStorageDriver` | `CRITICAL` | `IO_READ_ERRORS` / `IO_WRITE_ERRORS` |
| 10 | **Unsafe Shutdowns** | `nvmeUnsafeShutdowns` increased since the previous check in `state.json` | `WARNING` | `UNSAFE_SHUTDOWN_DETECTED` |
| 11 | **Disk Free Space** | Free space drops below `freeSpaceWarningPercent` or `freeSpaceCriticalPercent` | `WARNING` / `CRITICAL` | `DISK_SPACE_WARNING` / `DISK_SPACE_CRITICAL` |
| 12 | **Canary & `fsck`** | Writable volume forced read-only, canary write fails, latency exceeds `canaryLatencyWarningMs`, or `verifyVolume` fails | `WARNING` / `CRITICAL` | `FILESYSTEM_READ_ONLY` / `CANARY_IO_ERROR` / `CANARY_HIGH_LATENCY` / `FSCK_VERIFY_FAILED` |

#### 5. Stateful Alert Cooldowns (`evaluateAndAlert`)
- Compares current issues against `logs/state.json` (`lastAlertEpochByCode`).
- Suppresses duplicate notifications for the same issue code within `alertCooldownMinutes` unless a new counter delta occurs (e.g., additional I/O errors or unsafe shutdowns).
- Automatically sends a recovery notification (`✅ Disk Health Restored`) when a drive transitions from `WARNING` or `CRITICAL` back to `HEALTHY`.
