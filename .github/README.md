# GitHub Actions CI/CD Pipeline (`.github/`)

This directory contains the automated Continuous Integration and Release Packaging pipeline for **Universal Disk Health Monitor**.

---

## Workflows

### [`workflows/ci-release.yml`](workflows/ci-release.yml)

Triggered automatically on every `push` to `main`, `pull_request` targeting `main`, version tag (`v*`), or manual `workflow_dispatch`:

1. **Universal macOS Compilation (`arm64` + `x86_64`)**:
   - Runs `./build_and_install.sh --package` on a `macos-14` runner to compile both Apple Silicon (`arm64`) and Intel (`x86_64`) slices and merge them via `lipo` into `DiskHealthMonitor.app`.
2. **Automated Test Suite Execution**:
   - Runs `./build_and_install.sh --test`, executing:
     - `test_disk_health_bridge` (C11 IOKit / APFS container / boundary safety unit tests)
     - `test_core_logic` (Swift unit tests for formatters, models, `SecretStore`, `ConfigManager`, 12-rule health evaluation engine, and `DiagnosticExporter`)
     - End-to-end CLI and JSON schema verification
3. **Release Asset Packaging & Publishing**:
   - Uploads `DiskHealthMonitor-macOS.zip`, `DiskHealthMonitor.dmg`, and `SHA256SUMS.txt` as downloadable **GitHub Actions Workflow Artifacts**.
   - Publishes or updates the **GitHub Release** (`v2.1.0` or pushed `v*` tag) with `DiskHealthMonitor-macOS.zip`, `DiskHealthMonitor.dmg`, and `SHA256SUMS.txt` attached on the repository's Releases page.
