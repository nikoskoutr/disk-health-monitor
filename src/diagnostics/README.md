# Diagnostic & Report Exporters (`src/diagnostics/`)

This directory generates comprehensive, portable system context snapshots and customer-facing reports for troubleshooting, hardware diagnostics, and warranty RMA claims.

---

## Files

### [`DiagnosticExporter.swift`](DiagnosticExporter.swift)

#### 1. JSON Diagnostic Bundle
Serialized via `exportDiagnosticReportJSON()` or `--export-diagnostics [path]`:
- **`system`**: macOS kernel release, host name, binary version, and target architecture (`arm64` / `x86_64`).
- **`detectedDevices`**: Full topology list of attached block storage devices (`DiskListAllDevices`) and resolved mount points (`DiskFindMountForBlockDevice`).
- **`hardware` & `smart`**: Target drive metadata, raw NVMe registers, wear percentage, available spare, and POH.
- **`filesystem` & `driverStats`**: Capacity, APFS purgeable space, read/write latencies, errors, and throughput.
- **`evaluation`**: Health severity, score (`0`–`100`), and array of detected issues with codes.
- **`configuration`**: Sanitized active parameters with credentials securely masked (`•••••••• (Protected)`).
- **`recentLogLines`**: Last 100 entries of `logs/health.log` with tokens redacted.

#### 2. Standalone HTML Health & RMA Report
Exported via `exportDiagnosticReportHTML()`, `--export-html [path]`, menu item (`⌘H`), or Settings UI:
- **Zero-Dependency Styling**: Fully self-contained responsive CSS with dark/light mode compatibility.
- **Hardware Summary & RMA Readiness**: Clear color-coded overall severity banner, drive serial number, model, bus speed, and operational counters formatted for hardware RMA submissions.
- **Raw S.M.A.R.T. & Driver Statistics**: Visual tabular presentation of controller temperatures, wear levels, spare health, I/O errors, and canary latency.

#### 3. Security & POSIX Permissions
All exported files (`.json` and `.html`) are written atomically with POSIX `0600` (`rw-------`) permissions to ensure local user privacy.
