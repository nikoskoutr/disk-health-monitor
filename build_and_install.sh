#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="DiskHealthMonitor"
BUNDLE_ID="${BUNDLE_ID:-io.github.disk-health-monitor}"
APP_BUNDLE="${SCRIPT_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
BINARY_PATH="${MACOS_DIR}/${APP_NAME}"
BUILD_CACHE_DIR="${SCRIPT_DIR}/.build-cache"
LAUNCH_AGENTS_DIR="${HOME}/Library/LaunchAgents"
SERVICE_PLIST="${LAUNCH_AGENTS_DIR}/${BUNDLE_ID}.plist"

# Handle test suite command
if [[ "${1:-}" == "--test" ]]; then
    "${SCRIPT_DIR}/tests/run_tests.sh"
    exit 0
fi

# Handle uninstall service command
if [[ "${1:-}" == "--uninstall-service" ]]; then
    echo "🛑 Unloading and removing LaunchAgent service..."
    launchctl bootout "gui/$(id -u)/${BUNDLE_ID}" 2>/dev/null || true
    rm -f "${SERVICE_PLIST}"
    echo "✅ Service uninstalled successfully."
    exit 0
fi

echo "🔨 Building ${APP_NAME}.app in ${SCRIPT_DIR}..."
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}" "${BUILD_CACHE_DIR}" "${SCRIPT_DIR}/logs"

# Migrate any legacy config/ directory files to logs/
if [[ -d "${SCRIPT_DIR}/config" ]]; then
    for f in health.log latest_status.json state.json launchd.out.log launchd.err.log; do
        if [[ -f "${SCRIPT_DIR}/config/${f}" ]]; then
            mv -f "${SCRIPT_DIR}/config/${f}" "${SCRIPT_DIR}/logs/${f}"
        fi
    done
    rmdir "${SCRIPT_DIR}/config" 2>/dev/null || true
fi

export TMPDIR="${BUILD_CACHE_DIR}"

# 1. Compile C IOKit/NVMe SMART Bridge
ARCH_FLAGS=(-mmacosx-version-min=13.0)
if [[ "${1:-}" == "--package" ]] || [[ "${1:-}" == "--universal" ]]; then
    echo "🌐 Building Universal Binary (arm64 + x86_64)..."
    ARCH_FLAGS+=(-arch arm64 -arch x86_64)
fi
clang -O2 -Wall -Wextra "${ARCH_FLAGS[@]}" -c "${SCRIPT_DIR}/src/bridge/DiskHealthBridge.c" -o "${BUILD_CACHE_DIR}/DiskHealthBridge.o"

# 2. Compile App Icon if needed
if [[ ! -f "${SCRIPT_DIR}/assets/AppIcon.icns" ]] || [[ "${1:-}" == "--regenerate-icon" ]]; then
    echo "🎨 Generating App Icon assets..."
    mkdir -p "${SCRIPT_DIR}/assets"
    swiftc -O \
        -module-cache-path "${BUILD_CACHE_DIR}/ModuleCache" \
        "${SCRIPT_DIR}/scripts/generate_app_icon.swift" \
        -framework AppKit \
        -o "${BUILD_CACHE_DIR}/generate_app_icon"
    "${BUILD_CACHE_DIR}/generate_app_icon" "${SCRIPT_DIR}/assets/AppIcon.png"
    
    ICONSET="${BUILD_CACHE_DIR}/AppIcon.iconset"
    mkdir -p "${ICONSET}"
    sips -z 16 16     "${SCRIPT_DIR}/assets/AppIcon.png" --out "${ICONSET}/icon_16x16.png" > /dev/null
    sips -z 32 32     "${SCRIPT_DIR}/assets/AppIcon.png" --out "${ICONSET}/icon_16x16@2x.png" > /dev/null
    sips -z 32 32     "${SCRIPT_DIR}/assets/AppIcon.png" --out "${ICONSET}/icon_32x32.png" > /dev/null
    sips -z 64 64     "${SCRIPT_DIR}/assets/AppIcon.png" --out "${ICONSET}/icon_32x32@2x.png" > /dev/null
    sips -z 128 128   "${SCRIPT_DIR}/assets/AppIcon.png" --out "${ICONSET}/icon_128x128.png" > /dev/null
    sips -z 256 256   "${SCRIPT_DIR}/assets/AppIcon.png" --out "${ICONSET}/icon_128x128@2x.png" > /dev/null
    sips -z 256 256   "${SCRIPT_DIR}/assets/AppIcon.png" --out "${ICONSET}/icon_256x256.png" > /dev/null
    sips -z 512 512   "${SCRIPT_DIR}/assets/AppIcon.png" --out "${ICONSET}/icon_256x256@2x.png" > /dev/null
    sips -z 512 512   "${SCRIPT_DIR}/assets/AppIcon.png" --out "${ICONSET}/icon_512x512.png" > /dev/null
    sips -z 1024 1024 "${SCRIPT_DIR}/assets/AppIcon.png" --out "${ICONSET}/icon_512x512@2x.png" > /dev/null
    iconutil -c icns "${ICONSET}" -o "${SCRIPT_DIR}/assets/AppIcon.icns"
    rm -rf "${ICONSET}" "${BUILD_CACHE_DIR}/generate_app_icon"
fi

if [[ -f "${SCRIPT_DIR}/assets/AppIcon.icns" ]]; then
    cp "${SCRIPT_DIR}/assets/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi

# 3. Gather all Swift source files from src/
SWIFT_SOURCES=()
while IFS= read -r -d '' file; do
    SWIFT_SOURCES+=("$file")
done < <(find "${SCRIPT_DIR}/src" -name "*.swift" -print0 | sort -z)

# 4. Compile Swift App + Link with C Bridge and macOS Frameworks
if [[ "${1:-}" == "--package" ]] || [[ "${1:-}" == "--universal" ]]; then
    swiftc -O -target arm64-apple-macos13.0 \
        -module-cache-path "${BUILD_CACHE_DIR}/ModuleCache-arm64" \
        -import-objc-header "${SCRIPT_DIR}/src/bridge/DiskHealthBridge.h" \
        "${SWIFT_SOURCES[@]}" \
        "${BUILD_CACHE_DIR}/DiskHealthBridge.o" \
        -framework Cocoa -framework SwiftUI -framework IOKit -framework CoreFoundation -framework UserNotifications -framework Security \
        -o "${BUILD_CACHE_DIR}/${APP_NAME}-arm64"

    swiftc -O -target x86_64-apple-macos13.0 \
        -module-cache-path "${BUILD_CACHE_DIR}/ModuleCache-x86_64" \
        -import-objc-header "${SCRIPT_DIR}/src/bridge/DiskHealthBridge.h" \
        "${SWIFT_SOURCES[@]}" \
        "${BUILD_CACHE_DIR}/DiskHealthBridge.o" \
        -framework Cocoa -framework SwiftUI -framework IOKit -framework CoreFoundation -framework UserNotifications -framework Security \
        -o "${BUILD_CACHE_DIR}/${APP_NAME}-x86_64"

    lipo -create -output "${BINARY_PATH}" "${BUILD_CACHE_DIR}/${APP_NAME}-arm64" "${BUILD_CACHE_DIR}/${APP_NAME}-x86_64"
    rm -f "${BUILD_CACHE_DIR}/${APP_NAME}-arm64" "${BUILD_CACHE_DIR}/${APP_NAME}-x86_64"
else
    swiftc -O \
        -module-cache-path "${BUILD_CACHE_DIR}/ModuleCache" \
        -import-objc-header "${SCRIPT_DIR}/src/bridge/DiskHealthBridge.h" \
        "${SWIFT_SOURCES[@]}" \
        "${BUILD_CACHE_DIR}/DiskHealthBridge.o" \
        -framework Cocoa \
        -framework SwiftUI \
        -framework IOKit \
        -framework CoreFoundation \
        -framework UserNotifications \
        -framework Security \
        -o "${BINARY_PATH}"
fi

rm -f "${BUILD_CACHE_DIR}/DiskHealthBridge.o"
chmod +x "${BINARY_PATH}"

# 4. Create Info.plist for Menu Bar Agent (LSUIElement = true)
cat << EOF > "${CONTENTS_DIR}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>Disk Health Monitor</string>
    <key>CFBundleDisplayName</key>
    <string>macOS Disk Health Monitor</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>2.1.0</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Ad-hoc code sign the bundle so macOS LaunchServices/Gatekeeper trusts it cleanly
codesign --force --deep --sign - "${APP_BUNDLE}" 2>/dev/null || true

# 5. Create local CLI wrapper symlink (build output, ignored by git)
ln -sf "${APP_NAME}.app/Contents/MacOS/${APP_NAME}" "${SCRIPT_DIR}/disk-health"

# Optional: Install CLI globally if requested
if [[ "${1:-}" == "--install-cli" ]]; then
    INSTALL_DIR=""
    if [ -d "/usr/local/bin" ] && [ -w "/usr/local/bin" ]; then
        INSTALL_DIR="/usr/local/bin"
    elif [ -d "${HOME}/.local/bin" ]; then
        INSTALL_DIR="${HOME}/.local/bin"
    fi

    if [ -n "${INSTALL_DIR}" ]; then
        ln -sf "${BINARY_PATH}" "${INSTALL_DIR}/disk-health"
        echo "✅ Installed CLI to ${INSTALL_DIR}/disk-health"
    else
        echo "⚠️  Could not find writable /usr/local/bin or ~/.local/bin to install CLI."
    fi
fi

echo "✅ Built ${APP_BUNDLE}"
echo "   CLI symlink: ${SCRIPT_DIR}/disk-health"

# 6. Service Installation
if [[ "${1:-}" == "--install-service" ]] || [[ "${1:-}" == "--service" ]]; then
    echo "📦 Installing LaunchAgent into ${LAUNCH_AGENTS_DIR}..."
    mkdir -p "${LAUNCH_AGENTS_DIR}"

    cat << EOF > "${SERVICE_PLIST}"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${BUNDLE_ID}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${BINARY_PATH}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${SCRIPT_DIR}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${SCRIPT_DIR}/logs/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>${SCRIPT_DIR}/logs/launchd.err.log</string>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
EOF

    # Reload service
    launchctl bootout "gui/$(id -u)/${BUNDLE_ID}" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "${SERVICE_PLIST}"
    echo "🚀 LaunchAgent registered: ${SERVICE_PLIST}"
fi

# 7. Release Packaging (--package)
if [[ "${1:-}" == "--package" ]]; then
    DIST_DIR="${SCRIPT_DIR}/dist"
    DMG_STAGE="${BUILD_CACHE_DIR}/dmg-stage"
    rm -rf "${DIST_DIR}" "${DMG_STAGE}"
    mkdir -p "${DIST_DIR}" "${DMG_STAGE}"

    echo "📦 Packaging Universal Release Assets into ${DIST_DIR}..."
    # Create macOS ZIP preserving bundle metadata and code signature
    ditto -c -k --sequesterRsrc --keepParent "${APP_BUNDLE}" "${DIST_DIR}/${APP_NAME}-macOS.zip"

    # Create macOS DMG with Applications symlink
    cp -R "${APP_BUNDLE}" "${DMG_STAGE}/"
    ln -s /Applications "${DMG_STAGE}/Applications"
    cp "${SCRIPT_DIR}/README.md" "${SCRIPT_DIR}/LICENSE" "${DMG_STAGE}/"
    hdiutil create -volname "Disk Health Monitor" \
        -srcfolder "${DMG_STAGE}" \
        -ov -format UDZO \
        "${DIST_DIR}/${APP_NAME}.dmg" > /dev/null 2>&1 || true
    rm -rf "${DMG_STAGE}"

    # Generate SHA-256 Checksums
    (
        cd "${DIST_DIR}"
        shasum -a 256 ./* > SHA256SUMS.txt
    )
    echo "✅ Release assets packaged in ${DIST_DIR}:"
    ls -lh "${DIST_DIR}"
fi

