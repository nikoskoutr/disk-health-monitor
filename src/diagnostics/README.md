# Diagnostic Report Exporter (`src/diagnostics/`)

This directory provides a self-contained diagnostic bundle generator that captures system context, all detected storage devices, the latest health telemetry snapshot, sanitized user configuration, and recent log entries into a single portable JSON file.

---

## Files

### [`DiagnosticExporter.swift`](DiagnosticExporter.swift)

#### 1. `DiagnosticReport` (`Codable`)
The top-level JSON structure produced by `DiagnosticExporter.shared.generateDiagnosticReport()`:
- **`generatedAt`**: ISO-8601 UTC timestamp of the export.
- **`osVersion`**: Full macOS version and build string (`ProcessInfo.processInfo.operatingSystemVersionString`).
- **`hostname`**: Local machine hostname.
- **`appVersion`**: Semantic version of Universal Disk Health Monitor (`"2.1.0"`).
- **`appArchitecture`**: Runtime architecture string (`"arm64 (Apple Silicon)"` or `"x86_64 (Intel)"`).
- **`redactedConfig`**: The active `DiskHealthConfig` passed through `ConfigManager.redactedConfig(_:)`, ensuring `telegramBotToken` is replaced with `"***REDACTED***"`.
- **`mountedDisks`**: Array of `DiagnosticDiskSummary` entries populated via the C bridge (`DiskListAllDevices()`) and dynamic mount resolution (`DiskFindMountForBlockDevice()`), listing every block storage device's BSD identifier, volume name, mount path, vendor, product, transport protocol, capacity, and internal/external status.
- **`latestSnapshot`**: The most recent `DiskHealthSnapshot` (either supplied directly by the running monitor or loaded from `logs/latest_status.json`).
- **`recentLogLines`**: Up to the last 100 lines of `logs/health.log` for troubleshooting historical events.

#### 2. Usage
- **From the UI**: Click **Export Diagnostics** in the menu bar dashboard or inside the **Diagnostics** tab of the Settings window (`Cmd+,`).
- **From the CLI**:
  ```bash
  ./disk-health --export-diagnostics ~/Desktop/disk_diagnostics.json
  ```
- Exported files are written atomically and restricted to POSIX `0600` (`rw-------`) permissions.
