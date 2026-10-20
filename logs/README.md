# Runtime Logs & State Directory (`logs/`)

This directory is the default runtime directory where **Universal Disk Health Monitor** maintains operational logs, telemetry snapshots, and persistent baselines.

> [!NOTE]
> All files in `logs/` (`*.log`, `*.json`, `*.lock`) are excluded via [`.gitignore`](../.gitignore) to ensure drive serial numbers, system identifiers, and telemetry snapshots are never committed to version control.

---

## Runtime File Directory

| File | Generating Component | Purpose & Format |
| :--- | :--- | :--- |
| `health.log` | `ConfigManager` | Append-only ISO-8601 operational log. Automatically rotated to `health.log.1` when exceeding 5 MB (`0600` permissions) |
| `latest_status.json` | `DiskHealthMonitor` | Pretty-printed JSON snapshot of the most recent `DiskHealthSnapshot` evaluation (`0600` permissions) |
| `state.json` | `DiskHealthMonitor` | Cross-session `DiskPersistentState` tracking historical error baselines, unsafe shutdowns, and scoped alert cooldowns (`0600` permissions) |
| `menubar.lock` | `SingleInstanceLock` | Non-blocking POSIX `flock` file containing the PID of the active menu bar process (`0600` permissions) |
| `launchd.out.log` / `.err.log` | `launchd` | Standard output and error streams for the periodic check daemon |
| `mount-watch.out.log` / `.err.log` | `launchd` | Standard output and error streams for the `/Volumes` mount watcher |
| `menubar.out.log` / `.err.log` | `launchd` | Standard output and error streams for the persistent menu bar daemon |
