# Automated Test Suite (`tests/`)

This directory contains the automated test harness for **Universal Disk Health Monitor**, comprising 14 low-level C11/IOKit tests, 33 Swift engine unit tests, and comprehensive CLI integration tests.

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
   - Compiles and runs 14 hardware-level unit tests against `IOKit`, `DiskArbitration`, and `CoreFoundation`.
   - Verifies device enumeration, auto-detection, APFS recursive physical store resolution, 128-bit NVMe S.M.A.R.T. decoding, Kelvin/Celsius boundary validation, SATA/AHCI detection, link speed normalization, and buffer truncation safety.
2. **Stage 2 — Swift Core Logic & Engine Unit Tests (`test_core_logic.swift`)**:
   - Executes 33 deterministic unit tests covering:
     - POSIX date, byte, and link speed formatters.
     - `Codable` serialization of snapshots and persistent baseline state.
     - Configuration precedence, `.env` parsing, and Keychain credential offloading.
     - All 12 health evaluation engine rules, thermal spike detection, and driver latency rules.
     - Thread safety of `ConfigManager`, `SecretStore`, and `SingleInstanceLock`.
     - Active canary file security (`O_NOFOLLOW | O_CLOEXEC`), subpath traversal sanitization, and sealed root fallbacks.
     - Volume verification privilege classification and dark-wake suppression.
     - Webhook payload building, URL redaction, and HTML report generation.
     - SSD endurance forecasting (`dailyTerabytesWritten`, `estimatedRemainingLifeFormatted`).
3. **Stage 3 — End-to-End CLI & JSON Integration Tests**:
   - Verifies `./disk-health --help`, `--list-disks`, `--status`, `--json`, and `--volume / --status`.
4. **Stage 4 — Diagnostic & Report Exporters**:
   - Validates sanitized `--export-config`, comprehensive `--export-diagnostics`, standalone `--export-html`, and unbuffered `--surface-scan quick`.
5. **Stage 5 — Bundle Assets & File Security Verification**:
   - Confirms binary ad-hoc codesigning, `Info.plist` bundle icon configuration, and `0600` POSIX permissions across runtime files.
