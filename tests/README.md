# Test Suite (`tests/`)

This directory contains the automated C/IOKit unit tests, Swift core engine unit tests, and end-to-end CLI integration tests for **Universal Disk Health Monitor**. All tests execute inside an isolated temporary sandbox (`DISK_HEALTH_CONFIG_DIR` / `DISK_HEALTH_LOGS_DIR`) and dynamically discover attached drives on the host macOS machine or CI runner.

---

## Running the Tests

You can run the test suite either via the main build script or directly:

```bash
# Via the main build script (builds the app first, then runs all 5 test stages)
./build_and_install.sh --test

# Directly via the test runner script
./tests/run_tests.sh
```

---

## Files

### 1. [`run_tests.sh`](run_tests.sh)
The master test runner that executes five verification stages inside an isolated sandbox directory (`.build-cache/test-sandbox`):
- **Stage 1 — C/IOKit Bridge Unit Tests (`test_disk_health_bridge`)**:
  - Compiles `src/bridge/DiskHealthBridge.c` together with `tests/test_disk_health_bridge.c` against `IOKit` and `CoreFoundation`, then executes the binary.
- **Stage 2 — Swift Core Logic & Health Engine Unit Tests (`test_core_logic`)**:
  - Compiles the core Swift modules (`HealthModels`, `SecretStore`, `ConfigManager`, `MacOSNotifier`, `TelegramNotifier`, `DiagnosticExporter`, `DiskHealthMonitor`) with `tests/test_core_logic.swift` and executes deterministic unit assertions.
- **Stage 3 — End-to-End CLI & JSON Integration Tests**:
  - Verifies `./disk-health --help`, `./disk-health --list-disks`, `./disk-health --status`, `./disk-health --json`, and `./disk-health --volume / --status`.
- **Stage 4 — Configuration & Diagnostic Exporters**:
  - Verifies `./disk-health --export-config` masks secrets by default (`Protected`) and `--export-config --unmasked` reveals them when explicitly requested.
  - Verifies `./disk-health --export-diagnostics` generates a complete diagnostic bundle (`reportVersion`, `evaluation`, `configuration`).
- **Stage 5 — Directory Layout & Bundle Asset Verification**:
  - Verifies `logs/`, `assets/AppIcon.png`, `assets/AppIcon.icns`, and `DiskHealthMonitor.app/Contents/Info.plist` (`CFBundleIconFile = AppIcon`).

### 2. [`test_disk_health_bridge.c`](test_disk_health_bridge.c)
C11 unit test harness verifying `DiskHealthBridge`:
- **Test 1 (`DiskListAllDevices`)**: Asserts that `DiskListAllDevices()` discovers block storage devices and populates `bsdName`, `interconnectType`, and bounded SMART fields.
- **Test 2 (`DiskReadHardwareMetrics("auto")`)**: Verifies automatic primary drive selection.
- **Test 3 (`DiskFindMountForBlockDevice`)**: Dynamically resolves active mount points for all discovered devices (including `disk0 -> /`) and verifies round-trip `DiskReadHardwareMetrics(mountPath)` lookup.
- **Test 4 (`DiskReadHardwareMetrics("/")`)**: Verifies APFS container-to-physical-store parent traversal on the internal system root volume (`/`).
- **Test 5 (`/dev/` Prefix & Substring Matching)**: Verifies `"disk0"` and `"/dev/disk0"` resolve identically and tests product name substring matching.
- **Test 6 (Nonexistent Device Handling)**: Verifies that querying bogus volume paths and device nodes (`disk99999`) returns `found == false` cleanly.
- **Test 7 (Null-Pointer & Buffer Truncation Safety)**: Verifies `NULL` pointers, `0` / negative buffer lengths, and 2-byte buffer truncation safety without memory corruption.

### 3. [`test_core_logic.swift`](test_core_logic.swift)
Swift unit test harness verifying domain logic, security, and the 12-rule health evaluation engine:
- **Test 1 (Formatters)**: Verifies `en_US_POSIX` 24-hour `shortTimeFormatter` (`HH:mm:ss`), `isoTimestampFormatter`, `formatBytes` (`MB`/`GB`/`TB`), and `formatLinkSpeed` (`480 Mbps` up to `40 Gbps`).
- **Test 2 (`Codable` Persistence)**: Verifies `HealthSeverity` rank ordering and `DiskPersistentState` / `DriveBaselineState` JSON round-trip serialization.
- **Test 3 (`ConfigManager` & `SecretStore` Security)**: Verifies plaintext tokens are stripped from `config.json` (`REDACTED_IN_KEYCHAIN`), `config.json` enforces `0600` permissions, and masked/unmasked exports behave as expected.
- **Test 4 (Health Evaluation Engine Rules)**: Verifies root volume (`/`) evaluation, `REQUIRED_PATH_MISSING` (`CRITICAL`), `DISK_SPACE_WARNING` (`WARNING`), `DISK_SPACE_CRITICAL` (`CRITICAL`), and `HW_DISCONNECTED` / `VOLUME_UNMOUNTED` (`CRITICAL`).
- **Test 5 (`DiagnosticExporter`)**: Verifies diagnostic report structure and ensures secret tokens are never leaked in diagnostic bundles.
