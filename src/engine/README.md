# Health Evaluation Engine (`src/engine/`)

This directory contains the core hardware and filesystem evaluation engine (`DiskHealthMonitor`) that orchestrates telemetry collection, active canary write testing, volume verification (`diskutil verifyVolume`), the 12-rule health evaluation pipeline, per-drive state persistence, and alert cooldown management.

---

## Files

### [`DiskHealthMonitor.swift`](DiskHealthMonitor.swift)

#### 1. Concurrency & Synchronization
- Synchronizes all engine operations, snapshot reads, per-drive state mutations, and baseline resets with an internal `engineLock` (`NSRecursiveLock`).
- Serializes state file persistence (`logs/state.json`) and snapshot publishing (`logs/latest_status.json`) safely across concurrent background timer iterations and main UI updates.

#### 2. Active Canary I/O Probe (`performCanaryProbe`)
- For mounted writable volumes, writes a unique timestamped verification payload to `<mountPath>/.disk_health_canary` with POSIX flags `O_CREAT | O_WRONLY | O_NOFOLLOW | O_CLOEXEC` and permissions `0600`.
- Forces an `fsync()` to ensure data reaches physical media, reads the payload back to verify byte integrity, safely removes the temporary file, and records round-trip latency (`canaryLatencyMs`).
- When evaluating the sealed macOS APFS system root (`/`), targets the writable user data volume backing path at `/System/Volumes/Data/private/tmp`.

#### 3. Deep Filesystem Verification (`runVolumeVerification`)
- When invoked with `--deep` (or **"Verify Volume"** in the UI / digest dispatches), executes `/usr/sbin/diskutil verifyVolume <target>`.
- Atomically captures target path and `driveKey` under `engineLock` before dispatching to prevent cross-drive attribution races.
- Features a 180-second watchdog timer with `NSLock`-synchronized timeout handling, non-blocking pipe drainage via `readToEnd()`, cancellable `DispatchWorkItem` escalation, and clean two-stage process termination (`SIGTERM` followed by `SIGKILL` escalation).

#### 4. The 12 Health Evaluation Rules (`evaluateHealth`)

| # | Rule Category | Trigger Condition | Severity | Issue Code |
| :--- | :--- | :--- | :--- | :--- |
| **1** | **Mount Availability & Subpaths** | Target volume unmounted, BSD device missing, or required subpaths absent | `CRITICAL` | `HW_DISCONNECTED`, `VOLUME_UNMOUNTED`, `REQUIRED_PATH_MISSING` |
| **2** | **Hardware SMART Status** | NVMe Critical Warning bitmask `!= 0` | `CRITICAL` | `SMART_CRITICAL_WARNING` |
| **3** | **NVMe Available Spare** | Available spare `<= threshold` / `< 10%` (`CRITICAL`) or `< 25%` (`WARNING`) | `WARNING` / `CRITICAL` | `SPARE_CRITICAL`, `SPARE_WARNING` |
| **4** | **NVMe Wear Level** | `percentageUsed >= 80%` (`WARNING`) or `>= 95%` (`CRITICAL`) | `WARNING` / `CRITICAL` | `WEAR_WARNING`, `WEAR_CRITICAL` |
| **5** | **Drive Temperature** | `temperatureCelsius >= tempWarningCelsius` or `>= tempCriticalCelsius` | `WARNING` / `CRITICAL` | `TEMP_WARNING`, `TEMP_CRITICAL` |
| **6** | **Host Thermal State** | `ProcessInfo.processInfo.thermalState == .critical` | `WARNING` | `HOST_THERMAL_CRITICAL` |
| **7** | **Media & Kernel I/O Errors** | Non-zero delta in `mediaErrors`, error log entries, or driver read/write errors/retries | `WARNING` / `CRITICAL` | `MEDIA_ERRORS`, `ERROR_LOG_INCREASED`, `IO_DRIVER_ERRORS`, `IO_DRIVER_RETRIES` |
| **8** | **I/O Latency Spikes** | Driver read/write latency exceeds threshold (`> 50 ms` warn, `> 200 ms` crit) for `>= 100` operations | `WARNING` / `CRITICAL` | `IO_LATENCY_WARNING`, `IO_LATENCY_CRITICAL` |
| **9** | **Bus Speed Negotiation** | External drive negotiated below `minExpectedUsbSpeedBps` | `WARNING` | `USB_LINK_DEGRADED` |
| **10** | **Unsafe Shutdowns** | `unsafeShutdowns` counter incremented relative to persisted baseline | `WARNING` | `NEW_UNSAFE_SHUTDOWN` |
| **11** | **Disk Free Space** | Used `%` above ceiling or free GB below configured floor | `WARNING` / `CRITICAL` | `DISK_SPACE_WARNING`, `DISK_SPACE_CRITICAL` |
| **12** | **Canary & Verification** | Filesystem mounted read-only, canary probe failed, canary latency `> 300 ms`, or `verifyVolume` failed | `WARNING` / `CRITICAL` | `VOLUME_READONLY`, `CANARY_IO_FAILED`, `CANARY_HIGH_LATENCY`, `VOLUME_VERIFY_FAILED` |

#### 5. Stateful Alert Cooldowns (`processAlertsAndDigestLocked`)
- Compares current issues against per-drive state in `logs/state.json` (`lastAlertTimestampByCode`, scoped as `"<driveKey>:<issueCode>"`).
- Suppresses duplicate notifications for the same issue code within `alertCooldownSeconds`.
- Preserves active cooldowns across drive switches without wiping state.
- Automatically dispatches recovery notifications (`RECOVERED — HEALTHY`) when a drive transitions from `WARNING` or `CRITICAL` back to `HEALTHY`, clearing scoped cooldowns for that drive.
