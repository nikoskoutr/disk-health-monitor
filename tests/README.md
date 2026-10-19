# Test Suite (`tests/`)

This directory contains the automated C/IOKit unit tests and end-to-end CLI integration tests for **Universal Disk Health Monitor**. All tests dynamically discover attached drives on the host macOS machine and do not rely on hardcoded volume names or device nodes.

---

## Running the Tests

You can run the test suite either via the main build script or directly:

```bash
# Via the main build script (builds the app first, then runs all tests)
./build_and_install.sh --test

# Directly via the test runner script
./tests/run_tests.sh
```

---

## Files

### 1. [`run_tests.sh`](run_tests.sh)
The master test runner that executes four verification stages:
- **Stage 1 — C/IOKit Bridge Unit Tests (`test_disk_health_bridge`)**:
  - Compiles `src/bridge/DiskHealthBridge.c` together with `tests/test_disk_health_bridge.c` against `IOKit` and `CoreFoundation`, then executes the test binary.
- **Stage 2 — End-to-End CLI & JSON Integration Tests**:
  - Verifies `./disk-health --help` and `./disk-health --list-disks`.
  - Verifies `./disk-health --status`, `./disk-health --json`, and `./disk-health --volume / --status`.
- **Stage 3 — Configuration & Diagnostic Exporters**:
  - Verifies `./disk-health --export-config` masks secrets by default (`Protected`) and `--export-config --unmasked` reveals them when explicitly requested.
  - Verifies `./disk-health --export-diagnostics` generates a complete diagnostic bundle (`reportVersion`, `mountedDisks`, `latestSnapshot`).
- **Stage 4 — Directory Layout & Bundle Asset Verification**:
  - Verifies `logs/`, `assets/AppIcon.png`, `assets/AppIcon.icns`, and `DiskHealthMonitor.app/Contents/Info.plist` (`CFBundleIconFile = AppIcon`).

### 2. [`test_disk_health_bridge.c`](test_disk_health_bridge.c)
Unified C11 test harness verifying `DiskHealthBridge`:
- **Test 1 (`DiskListAllDevices`)**: Asserts that `DiskListAllDevices()` discovers block storage devices and populates `bsdName`, `interconnectType`, and SMART fields.
- **Test 2 (`DiskReadHardwareMetrics("auto")`)**: Verifies automatic primary drive selection.
- **Test 3 (`DiskFindMountForBlockDevice`)**: Dynamically resolves active mount points for all discovered devices (including `disk0 -> /`) and verifies round-trip `DiskReadHardwareMetrics(mountPath)` lookup.
- **Test 4 (`DiskReadHardwareMetrics("/")`)**: Verifies APFS container-to-physical-store parent traversal on the internal system root volume (`/`).
- **Test 5 (Nonexistent Device Handling)**: Verifies that querying a bogus volume path (`/Volumes/__NonExistentVolume_99999__`) returns `found == false` cleanly without crashing or leaking IOKit references.
