# Diagnostic Report Exporter (`src/diagnostics/`)

This directory provides a self-contained diagnostic bundle generator that captures system context, all detected storage devices, the latest health telemetry snapshot, sanitized user configuration, and recent log entries into a single portable JSON file.

---

## Files

### [`DiagnosticExporter.swift`](DiagnosticExporter.swift)

#### 1. Diagnostic Report Structure
The JSON dictionary produced by `DiagnosticExporter.shared.generateDiagnosticReport()` and serialized by `exportDiagnosticReportJSON()`:
- **`reportVersion`**: Semantic report schema version (`"2.1.0"`).
- **`timestamp`**: ISO-8601 UTC timestamp of the export.
- **`system`**: Operating system version, hostname, app version, and architecture (`arm64` or `x86_64`).
- **`target`**: Active monitored `volumePath` and `deviceQuery`.
- **`detectedDevices`**: Array of all block storage devices enumerated via `DiskListAllDevices()` and mount points resolved via `DiskFindMountForBlockDevice()`.
- **`hardware`**: Hardware metadata for the target disk (vendor, product, BSD name, interconnect, bus speed).
- **`filesystem`**: Filesystem metrics (mount point, capacity, free space, used percentage, read-only status, verification result).
- **`smart`**: NVMe SMART attributes (temperature, spare, wear level, TBW, power cycles, unsafe shutdowns, media errors).
- **`driverStats`**: Kernel storage driver statistics (read/write latencies, errors, retries, throughput).
- **`canary`**: Active I/O canary probe status and round-trip latency.
- **`evaluation`**: Overall health severity, score (0–100), and list of detected issues.
- **`configuration`**: Active monitoring parameters with sensitive secrets securely masked (`•••••••• (Protected)`).
- **`recentLogLines`**: Up to the last 100 lines of `logs/health.log` for troubleshooting historical events.

#### 2. Usage
- **From the UI**: Click **Export Diagnostics** in the menu bar dashboard or inside the **Diagnostics** tab of the Settings window (`Cmd+,`).
- **From the CLI**:
  ```bash
  ./disk-health --export-diagnostics ~/Desktop/disk_diagnostics.json
  ```
- Exported files are written atomically and restricted to POSIX `0600` (`rw-------`) permissions.
