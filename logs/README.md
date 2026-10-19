# Runtime Logs & State Directory (`logs/`)

This directory is the default runtime workspace where **Universal Disk Health Monitor** writes operational logs, the latest health telemetry snapshot, and cross-session state deltas.

> [!NOTE]
> All runtime files generated inside `logs/` (`*.log`, `state.json`, `latest_status.json`, `diagnostic_*.json`) are listed in [`.gitignore`](../.gitignore) so personal drive serial numbers, hostnames, and runtime telemetry are never committed to Git.

---

## Runtime Files Generated in `logs/`

| File | Created By | Purpose |
| :--- | :--- | :--- |
| `health.log` | [`ConfigManager`](../src/config/ConfigManager.swift) | Append-only ISO-8601 operational log recording check results, detected anomalies, configuration changes, and notification deliveries |
| `latest_status.json` | [`DiskHealthMonitor`](../src/engine/DiskHealthMonitor.swift) | Pretty-printed JSON serialization of the most recent [`DiskHealthSnapshot`](../src/models/HealthModels.swift) |
| `state.json` | [`DiskHealthMonitor`](../src/engine/DiskHealthMonitor.swift) | Persistent [`DiskPersistentState`](../src/models/HealthModels.swift) tracking previous severity, per-issue alert cooldown epochs (`lastAlertEpochByCode`), and cumulative error/shutdown counters for delta detection |
| `launchd.out.log` / `launchd.err.log` | `launchd` | Standard output and standard error streams captured when background LaunchAgents are installed via `./build_and_install.sh --install-service` |
| `mount-watch.out.log` / `mount-watch.err.log` | `launchd` | Output streams for the `/Volumes` mount-watcher LaunchAgent |
| `menubar.out.log` / `menubar.err.log` | `launchd` | Output streams for the persistent menu bar LaunchAgent |
