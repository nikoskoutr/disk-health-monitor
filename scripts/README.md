# Build & Asset Utilities (`scripts/`)

This directory contains standalone build utilities used during asset compilation and application packaging.

---

## Files

### [`generate_app_icon.swift`](generate_app_icon.swift)
A standalone Swift script that programmatically renders the application's macOS branding assets (`assets/AppIcon.png` and `assets/AppIcon.icns`) using native **CoreGraphics** and **AppKit** vector graphics APIs—with zero third-party dependencies.

#### Visual Elements Rendered:
1. **macOS Squircle Base**: 1024×1024 rounded rectangle (`cornerRadius = 225`) with a slate-to-deep-navy linear gradient (`#121A2E` to `#0A2E3D`) and a subtle cyan inner border glow.
2. **Metallic Storage Enclosure**: Detailed brushed-finish SSD/NVMe drive chassis with dual LED activity indicators.
3. **Live Telemetry Waveform**: Emerald-cyan ECG/telemetry pulse line across the center of the drive, symbolizing active S.M.A.R.T. monitoring and physical media integrity.

#### Multi-Resolution Asset Compilation:
When invoked during `./build_and_install.sh`:
1. Renders the master 1024×1024 PNG (`assets/AppIcon.png`).
2. Scales individual resolutions (`16×16` through `512×512@2x`) into an `.iconset` folder via `/usr/bin/sips`.
3. Packages the icon set into `assets/AppIcon.icns` via `/usr/bin/iconutil`.
