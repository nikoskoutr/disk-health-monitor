# Application Assets (`assets/`)

This directory stores the visual branding and icon assets bundled into `DiskHealthMonitor.app/Contents/Resources/`.

---

## Files

| File | Format / Dimensions | Purpose |
| :--- | :--- | :--- |
| [`AppIcon.png`](AppIcon.png) | 1024×1024 RGBA PNG | Master high-resolution application icon rendered by [`scripts/generate_app_icon.swift`](../scripts/generate_app_icon.swift) |
| [`AppIcon.icns`](AppIcon.icns) | Apple Icon Image (`.icns`) | Multi-resolution icon bundle (`16x16` up to `512x512@2x`) referenced by `CFBundleIconFile` in `DiskHealthMonitor.app/Contents/Info.plist` and displayed in Finder, Dock, Settings (`Cmd+,`), and macOS Notification Center alerts |

---

## Regenerating the Icon

To regenerate both `AppIcon.png` and `AppIcon.icns` from source:

```bash
rm -f assets/AppIcon.png assets/AppIcon.icns
./build_and_install.sh
```
