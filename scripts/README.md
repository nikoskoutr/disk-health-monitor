# Build & Asset Generation Scripts (`scripts/`)

This directory contains standalone helper scripts executed during the build pipeline (`./build_and_install.sh`).

---

## Files

### [`generate_app_icon.swift`](generate_app_icon.swift)
A self-contained Swift script that programmatically renders the application's macOS icon (`assets/AppIcon.png` and `assets/AppIcon.icns`) using native **CoreGraphics** and **AppKit** vector drawing APIs—requiring no external design assets or third-party image libraries.

#### What It Renders:
1. **macOS Squircle Background**: Draws a 1024×1024 rounded-rectangle squircle (`cornerRadius = 225`) with a deep slate-blue radial/linear gradient (`#121A2E` to `#0A2E3D`) and a subtle cyan inner border glow.
2. **Drive Enclosure Chassis**: Renders a brushed metallic SSD/NVMe drive body with dual LED activity indicators (emerald green & cyan).
3. **Live Pulse / Telemetry Waveform**: Draws a glowing emerald-cyan ECG/telemetry waveform across the center of the drive, symbolizing active real-time SMART and I/O monitoring.

#### Multi-Resolution `.icns` Conversion:
After rendering the master 1024×1024 PNG (`assets/AppIcon.png`), `build_and_install.sh` generates a complete `.iconset` directory (`16x16` through `512x512@2x`) using `/usr/bin/sips` and compiles it into `assets/AppIcon.icns` via `/usr/bin/iconutil`.
