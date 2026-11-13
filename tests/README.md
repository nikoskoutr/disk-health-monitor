# Automated Test Suite (`tests/`)

This directory contains the automated test harness for **Universal Disk Health Monitor**, comprising **26** low-level C11/IOKit tests, **68** Swift engine unit test suites, and comprehensive CLI integration tests.

All tests run inside an isolated temporary sandbox (`.build-cache/test-sandbox`) to ensure tests do not alter user configuration or production logs.

---

## Running Tests

```bash
# Run all 5 test stages via the main build script (recommended)
./build_and_install.sh --test

# Or execute the test runner directly
./tests/run_tests.sh
```

---

## Test Stages (`run_tests.sh`)

1. **Stage 1 — C11 / IOKit Bridge Unit Tests (`test_disk_health_bridge.c`)**:
   - Compiles and runs all translation units (`src/bridge/*.c`) through 26 hardware-level unit tests against `IOKit`, `DiskArbitration`, and `CoreFoundation`.
   - Verifies device enumeration, auto-detection, APFS physical store & container volume resolution, 128-bit NVMe S.M.A.R.T. decoding, SAT ATA pass-through, Kelvin/Celsius & HID die thermal sensors, SATA/AHCI detection, link speed normalization, `DiskSampleProcessIoMetrics`, scoped `DiskListProcessOpenFilesOnMount`, PID-reuse-safe `DiskVerifyBlockerForTermination`, `DiskIsDarkWakeActive`, `DiskResolvePhysicalExtent`, and buffer truncation safety.
2. **Stage 2 — Swift Core Logic & Engine Unit Tests (`test_core_logic.swift`)**:
   - Executes 68 deterministic unit test suites covering:
     - POSIX date, byte, and link speed formatters.
     - `Codable` serialization of snapshots, automation schemas (`AutomationModels.swift`), and persistent baseline state (`PersistentStateStore`).
     - Configuration precedence (`applyKeyValueMap`), `.env` parsing, and Keychain credential offloading (`SecretStore`).
     - All 15 health evaluation engine rules (including HID thermal fallback, `BusSignalIntegrityRule`, `ApfsSwapPressureRule`, and `ControllerQuarantineRule`).
     - Thread safety of `ConfigManager`, `SecretStore`, `SingleInstanceLock`, `AlertCoordinator`, and lock-split `ParallelDriveProber` (circuit breakers, 120s quarantine TTL, Dark Wake deferral).
     - `SubprocessRunner` (`POSIX_SPAWN_SETPGROUP`, 1 MiB cap, PGID timeout termination), `TelemetryHistoryStore` (90d hourly JSONL OLS regression & retention), `OpenMetricsServer`, `ApfsSnapshotService`, `OpenFileBlockerInspector`, and `PowerManagementService`.
     - Webhook payload building, URL redaction, standalone HTML/JSON RMA generation, and SSD endurance forecasting.
3. **Stage 3 — End-to-End CLI & JSON Integration Tests**:
   - Verifies `--help`, `--version`, `--list-disks`, `--list-rules`, `--simulate-rule`, `--top-io`, `--who-blocks`, `--snapshots`, `--container-info`, `--pre-sleep-shield status`, `--status`, `--json`, `--check`, `--watch-mounts`, `--deep`, symlink `O_NOFOLLOW` protection, and `POSIX_SPAWN_SETSID` detachment.
4. **Stage 4 — Diagnostic & Report Exporters**:
   - Validates sanitized `--export-config`, `--import-config`, comprehensive `--export-diagnostics`, standalone `--export-html`, unbuffered `--surface-scan` (`quick` and `standard`), and `--test-alert-script`.
5. **Stage 5 — Bundle Assets & File Security Verification**:
   - Confirms binary ad-hoc codesigning, `Info.plist` bundle icon configuration, and `0600` POSIX permissions across runtime files.
