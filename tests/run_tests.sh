#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_CACHE="${ROOT_DIR}/.build-cache"
TEST_SANDBOX_DIR="${BUILD_CACHE}/test-sandbox"

mkdir -p "${BUILD_CACHE}"
rm -rf "${TEST_SANDBOX_DIR}"
mkdir -p "${TEST_SANDBOX_DIR}/config" "${TEST_SANDBOX_DIR}/logs"

export TMPDIR="${BUILD_CACHE}"
export DISK_HEALTH_CONFIG_DIR="${TEST_SANDBOX_DIR}/config"
export DISK_HEALTH_LOGS_DIR="${TEST_SANDBOX_DIR}/logs"

echo "================================================================================"
echo "🧪 RUNNING DISK HEALTH MONITOR TEST SUITE"
echo "================================================================================"

# 1. Test DiskHealthBridge C Unit Tests
echo "--- [1/5] Building & Running test_disk_health_bridge (C/IOKit Unit Tests) ---"
clang -O2 -Wall -Wextra -c "${ROOT_DIR}/src/bridge/DiskHealthBridge.c" -o "${BUILD_CACHE}/DiskHealthBridge_test.o"
clang -O2 -Wall -Wextra -I"${ROOT_DIR}/src/bridge" -I"${ROOT_DIR}" \
    "${SCRIPT_DIR}/test_disk_health_bridge.c" \
    "${BUILD_CACHE}/DiskHealthBridge_test.o" \
    -framework IOKit -framework CoreFoundation \
    -o "${BUILD_CACHE}/test_disk_health_bridge"
"${BUILD_CACHE}/test_disk_health_bridge"
echo "✅ test_disk_health_bridge passed!"

# 2. Test Swift Core Logic & Health Evaluation Engine Unit Tests
echo "--- [2/5] Building & Running test_core_logic (Swift Engine & Config Unit Tests) ---"
swiftc -O \
    -module-cache-path "${BUILD_CACHE}/ModuleCache" \
    -import-objc-header "${ROOT_DIR}/src/bridge/DiskHealthBridge.h" \
    "${ROOT_DIR}/src/models/HealthModels.swift" \
    "${ROOT_DIR}/src/security/SecretStore.swift" \
    "${ROOT_DIR}/src/security/SingleInstanceLock.swift" \
    "${ROOT_DIR}/src/config/ConfigManager.swift" \
    "${ROOT_DIR}/src/notifications/MacOSNotifier.swift" \
    "${ROOT_DIR}/src/notifications/TelegramNotifier.swift" \
    "${ROOT_DIR}/src/notifications/WebhookNotifier.swift" \
    "${ROOT_DIR}/src/diagnostics/DiagnosticExporter.swift" \
    "${ROOT_DIR}/src/engine/DiskHealthMonitor.swift" \
    "${ROOT_DIR}/src/ui/DashboardMenuView.swift" \
    "${ROOT_DIR}/src/ui/AppDelegate.swift" \
    "${ROOT_DIR}/src/ui/SettingsView.swift" \
    "${SCRIPT_DIR}/test_core_logic.swift" \
    "${BUILD_CACHE}/DiskHealthBridge_test.o" \
    -framework Cocoa \
    -framework SwiftUI \
    -framework IOKit \
    -framework CoreFoundation \
    -framework UserNotifications \
    -framework Security \
    -o "${BUILD_CACHE}/test_core_logic"
"${BUILD_CACHE}/test_core_logic"
rm -f "${BUILD_CACHE}/DiskHealthBridge_test.o"

# 3. Test CLI binary commands
echo "--- [3/5] Testing CLI Binary Options ---"
"${ROOT_DIR}/disk-health" --help > /dev/null
echo "  [OK] disk-health --help"

VERSION_OUTPUT="$("${ROOT_DIR}/disk-health" --version)"
if echo "${VERSION_OUTPUT}" | grep -q "Universal Disk Health Monitor" && (echo "${VERSION_OUTPUT}" | grep -q -E "arm64|x86_64"); then
    echo "  [OK] disk-health --version (${VERSION_OUTPUT})"
else
    echo "  [FAIL] disk-health --version failed or missing architecture label: ${VERSION_OUTPUT}"
    exit 1
fi

"${ROOT_DIR}/disk-health" -v > /dev/null
echo "  [OK] disk-health -v"

"${ROOT_DIR}/disk-health" --list-disks > /dev/null
echo "  [OK] disk-health --list-disks"

set +e
"${ROOT_DIR}/disk-health" --status > "${BUILD_CACHE}/status_output.txt"
STATUS_EXIT=$?
set -e
if [[ ${STATUS_EXIT} -le 2 ]] && grep -q "DISK HEALTH MONITOR" "${BUILD_CACHE}/status_output.txt"; then
    echo "  [OK] disk-health --status (exit code: ${STATUS_EXIT})"
else
    echo "  [FAIL] disk-health --status failed or crashed with exit code ${STATUS_EXIT}"
    cat "${BUILD_CACHE}/status_output.txt"
    exit 1
fi

set +e
"${ROOT_DIR}/disk-health" --json > "${BUILD_CACHE}/json_output.txt"
JSON_EXIT=$?
set -e
if [[ ${JSON_EXIT} -le 2 ]] && grep -q "overallSeverity" "${BUILD_CACHE}/json_output.txt"; then
    echo "  [OK] disk-health --json (exit code: ${JSON_EXIT})"
else
    echo "  [FAIL] disk-health --json failed or crashed with exit code ${JSON_EXIT}"
    cat "${BUILD_CACHE}/json_output.txt"
    exit 1
fi

set +e
"${ROOT_DIR}/disk-health" --volume / --status > "${BUILD_CACHE}/vol_status_output.txt"
VOL_EXIT=$?
set -e
if [[ ${VOL_EXIT} -le 2 ]] && grep -q "DISK HEALTH MONITOR" "${BUILD_CACHE}/vol_status_output.txt"; then
    echo "  [OK] disk-health --volume / --status (exit code: ${VOL_EXIT})"
else
    echo "  [FAIL] disk-health --volume / --status failed or crashed with exit code ${VOL_EXIT}"
    cat "${BUILD_CACHE}/vol_status_output.txt"
    exit 1
fi

set +e
"${ROOT_DIR}/disk-health" --volume --status > /dev/null 2>&1
MISSING_VOL_FLAG_EXIT=$?
"${ROOT_DIR}/disk-health" --volume > /dev/null 2>&1
MISSING_VOL_END_EXIT=$?
"${ROOT_DIR}/disk-health" --device --check > /dev/null 2>&1
MISSING_DEV_FLAG_EXIT=$?
"${ROOT_DIR}/disk-health" --device > /dev/null 2>&1
MISSING_DEV_END_EXIT=$?
set -e
if [[ ${MISSING_VOL_FLAG_EXIT} -eq 1 ]] && [[ ${MISSING_VOL_END_EXIT} -eq 1 ]] && \
   [[ ${MISSING_DEV_FLAG_EXIT} -eq 1 ]] && [[ ${MISSING_DEV_END_EXIT} -eq 1 ]]; then
    echo "  [OK] disk-health rejects missing --volume / --device arguments across all positions (exit code: 1)"
else
    echo "  [FAIL] disk-health did not reject missing --volume (${MISSING_VOL_FLAG_EXIT}, ${MISSING_VOL_END_EXIT}) or --device (${MISSING_DEV_FLAG_EXIT}, ${MISSING_DEV_END_EXIT}) arguments"
    exit 1
fi

set +e
"${ROOT_DIR}/disk-health" --check > "${BUILD_CACHE}/check_output.txt"
CHECK_EXIT=$?
set -e
if [[ ${CHECK_EXIT} -le 2 ]] && grep -q "DISK HEALTH MONITOR" "${BUILD_CACHE}/check_output.txt"; then
    echo "  [OK] disk-health --check (exit code: ${CHECK_EXIT})"
else
    echo "  [FAIL] disk-health --check failed or crashed with exit code ${CHECK_EXIT}"
    cat "${BUILD_CACHE}/check_output.txt"
    exit 1
fi

set +e
"${ROOT_DIR}/disk-health" --watch-mounts > "${BUILD_CACHE}/watch_output.txt"
WATCH_EXIT=$?
set -e
if [[ ${WATCH_EXIT} -le 2 ]] && grep -q "DISK HEALTH MONITOR" "${BUILD_CACHE}/watch_output.txt"; then
    echo "  [OK] disk-health --watch-mounts (exit code: ${WATCH_EXIT})"
else
    echo "  [FAIL] disk-health --watch-mounts failed or crashed with exit code ${WATCH_EXIT}"
    cat "${BUILD_CACHE}/watch_output.txt"
    exit 1
fi

set +e
"${ROOT_DIR}/disk-health" --deep > "${BUILD_CACHE}/deep_output.txt"
DEEP_EXIT=$?
set -e
if [[ ${DEEP_EXIT} -le 2 ]] && grep -q "DISK HEALTH MONITOR" "${BUILD_CACHE}/deep_output.txt"; then
    echo "  [OK] disk-health --deep (exit code: ${DEEP_EXIT})"
else
    echo "  [FAIL] disk-health --deep failed or crashed with exit code ${DEEP_EXIT}"
    cat "${BUILD_CACHE}/deep_output.txt"
    exit 1
fi

# Verify SingleInstanceLock O_NOFOLLOW symlink rejection in live binary (IMPROVE-V8-02)
SYMLINK_TARGET="${TEST_SANDBOX_DIR}/symlink_target.txt"
SYMLINK_LOCK="${DISK_HEALTH_CONFIG_DIR}/menubar.lock"
echo "CRITICAL_SYSTEM_DATA" > "${SYMLINK_TARGET}"
ln -sf "${SYMLINK_TARGET}" "${SYMLINK_LOCK}"
DISK_HEALTH_NO_DETACH=1 "${ROOT_DIR}/disk-health" --menubar > /dev/null 2>&1 || true
if [[ "$(cat "${SYMLINK_TARGET}")" == "CRITICAL_SYSTEM_DATA" ]]; then
    echo "  [OK] SingleInstanceLock O_NOFOLLOW symlink protection verified"
else
    echo "  [FAIL] SingleInstanceLock compromised symlink target!"
    exit 1
fi
rm -f "${SYMLINK_LOCK}" "${SYMLINK_TARGET}"

# Verify POSIX_SPAWN_SETSID Terminal detachment: parent must exit 0 immediately without blocking
DETACH_LOCK="${DISK_HEALTH_CONFIG_DIR}/menubar.lock"
# Pre-hold the single instance lock in a subshell so the detached child exits cleanly without opening a GUI status bar item during tests
/usr/bin/python3 -c '
import fcntl, os, subprocess, sys, time
lock_path = sys.argv[1]
bin_path = sys.argv[2]
fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
env = dict(os.environ)
env["TERM_PROGRAM"] = "Apple_Terminal"
env["DISK_HEALTH_FORCE_DETACH_TEST"] = "1"
t0 = time.time()
res = subprocess.run([bin_path, "--menubar"], env=env, timeout=3.0)
dt = time.time() - t0
assert res.returncode == 0, f"Expected returncode 0, got {res.returncode}"
assert dt < 2.0, f"Parent did not detach immediately (took {dt:.2f}s)"
time.sleep(0.2)
fcntl.flock(fd, fcntl.LOCK_UN)
os.close(fd)
' "${DETACH_LOCK}" "${ROOT_DIR}/disk-health"
rm -f "${DETACH_LOCK}"
echo "  [OK] POSIX_SPAWN_SETSID Terminal detachment verified (parent exits 0 immediately)"

# 4. Test Export & Import Configuration & Diagnostics
echo "--- [4/5] Testing Config & Diagnostic Exporters ---"
TEST_IMPORT_PATH="${TEST_SANDBOX_DIR}/config/import_test.json"
echo '{"pollIntervalSeconds": 22.0, "tempWarningCelsius": 48}' > "${TEST_IMPORT_PATH}"
"${ROOT_DIR}/disk-health" --import-config "${TEST_IMPORT_PATH}" > "${BUILD_CACHE}/import_cli_output.txt"
if grep -q "Configuration imported successfully" "${BUILD_CACHE}/import_cli_output.txt"; then
    echo "  [OK] disk-health --import-config"
else
    echo "  [FAIL] disk-health --import-config failed"
    cat "${BUILD_CACHE}/import_cli_output.txt"
    exit 1
fi
TEST_SECRET_TOKEN="test_secret_bot_token_8899"
CONFIG_EXPORT="$(TELEGRAM_BOT_TOKEN="${TEST_SECRET_TOKEN}" "${ROOT_DIR}/disk-health" --export-config)"
if echo "${CONFIG_EXPORT}" | grep -q "Protected" && ! echo "${CONFIG_EXPORT}" | grep -q "${TEST_SECRET_TOKEN}"; then
    echo "  [OK] disk-health --export-config masks secrets"
else
    echo "  [FAIL] disk-health --export-config did not mask secrets properly"
    echo "${CONFIG_EXPORT}"
    exit 1
fi

UNMASKED_EXPORT="$(TELEGRAM_BOT_TOKEN="${TEST_SECRET_TOKEN}" "${ROOT_DIR}/disk-health" --export-config --unmasked)"
if echo "${UNMASKED_EXPORT}" | grep -q "${TEST_SECRET_TOKEN}"; then
    echo "  [OK] disk-health --export-config --unmasked unmasks secrets"
else
    echo "  [FAIL] disk-health --export-config --unmasked failed to output secret"
    echo "${UNMASKED_EXPORT}"
    exit 1
fi

CLEAN_EXPORT="$(TELEGRAM_BOT_TOKEN="" "${ROOT_DIR}/disk-health" --export-config)"
if echo "${CLEAN_EXPORT}" | grep -q "alertCooldownSeconds"; then
    echo "  [OK] disk-health --export-config outputs valid configuration structure"
else
    echo "  [FAIL] disk-health --export-config failed on clean configuration"
    exit 1
fi

TEST_DIAG_PATH="${TEST_SANDBOX_DIR}/logs/test_diag_export.json"
"${ROOT_DIR}/disk-health" --export-diagnostics "${TEST_DIAG_PATH}" > /dev/null
if [[ -f "${TEST_DIAG_PATH}" ]] && grep -q "reportVersion" "${TEST_DIAG_PATH}"; then
    echo "  [OK] disk-health --export-diagnostics generated valid report"
    rm -f "${TEST_DIAG_PATH}"
else
    echo "  [FAIL] disk-health --export-diagnostics failed to produce report"
    exit 1
fi

TEST_HTML_PATH="${TEST_SANDBOX_DIR}/logs/test_diag_export.html"
"${ROOT_DIR}/disk-health" --export-html "${TEST_HTML_PATH}" > /dev/null
if [[ -f "${TEST_HTML_PATH}" ]] && grep -q "<!DOCTYPE html>" "${TEST_HTML_PATH}"; then
    echo "  [OK] disk-health --export-html generated valid HTML report"
    rm -f "${TEST_HTML_PATH}"
else
    echo "  [FAIL] disk-health --export-html failed to produce report"
    exit 1
fi

set +e
"${ROOT_DIR}/disk-health" --surface-scan quick > "${BUILD_CACHE}/surface_scan_output.txt"
SURFACE_EXIT=$?
set -e
if [[ ${SURFACE_EXIT} -le 2 ]] && grep -q "Surface Read Validation" "${BUILD_CACHE}/surface_scan_output.txt"; then
    echo "  [OK] disk-health --surface-scan quick executed successfully (exit code: ${SURFACE_EXIT})"
else
    echo "  [FAIL] disk-health --surface-scan quick failed or crashed with exit code ${SURFACE_EXIT}"
    cat "${BUILD_CACHE}/surface_scan_output.txt"
    exit 1
fi

set +e
"${ROOT_DIR}/disk-health" --surface-scan=standard > "${BUILD_CACHE}/surface_scan_standard_output.txt"
SURFACE_STD_EXIT=$?
set -e
if [[ ${SURFACE_STD_EXIT} -le 2 ]] && grep -q "Surface Read Validation" "${BUILD_CACHE}/surface_scan_standard_output.txt"; then
    echo "  [OK] disk-health --surface-scan=standard executed successfully (exit code: ${SURFACE_STD_EXIT})"
else
    echo "  [FAIL] disk-health --surface-scan=standard failed or crashed with exit code ${SURFACE_STD_EXIT}"
    cat "${BUILD_CACHE}/surface_scan_standard_output.txt"
    exit 1
fi

TEST_HOOK_SCRIPT="${TEST_SANDBOX_DIR}/test_hook.sh"
TEST_HOOK_LOG="${TEST_SANDBOX_DIR}/test_hook_out.txt"
cat << EOF > "${TEST_HOOK_SCRIPT}"
#!/bin/sh
echo "HOOK_OK event=\${DISK_HEALTH_EVENT} device=\${DISK_HEALTH_DEVICE}" > "${TEST_HOOK_LOG}"
EOF
chmod +x "${TEST_HOOK_SCRIPT}"
HOOK_OUT="$(ALERT_SCRIPT_PATH="${TEST_HOOK_SCRIPT}" "${ROOT_DIR}/disk-health" --test-alert-script 2>&1)"
if echo "${HOOK_OUT}" | grep -q "Alert script executed successfully" && grep -q "HOOK_OK" "${TEST_HOOK_LOG}"; then
    echo "  [OK] disk-health --test-alert-script executed hook successfully"
    rm -f "${TEST_HOOK_SCRIPT}" "${TEST_HOOK_LOG}"
else
    echo "  [FAIL] disk-health --test-alert-script failed"
    echo "${HOOK_OUT}"
    exit 1
fi

# 5. Verify Project Assets & Directory Standardization
echo "--- [5/5] Verifying Directory Layout & AppIcon Bundle Assets ---"
if [[ -d "${ROOT_DIR}/logs" ]]; then
    echo "  [OK] logs/ directory exists"
else
    echo "  [FAIL] logs/ directory missing"
    exit 1
fi

if [[ ! -d "${ROOT_DIR}/config" ]]; then
    echo "  [OK] obsolete root config/ directory does not exist"
else
    echo "  [FAIL] obsolete root config/ directory still exists"
    exit 1
fi

if [[ -f "${ROOT_DIR}/assets/AppIcon.icns" ]] && [[ -f "${ROOT_DIR}/assets/AppIcon.png" ]]; then
    echo "  [OK] AppIcon assets exist in assets/"
else
    echo "  [FAIL] AppIcon assets missing in assets/"
    exit 1
fi

if [[ -f "${ROOT_DIR}/DiskHealthMonitor.app/Contents/Resources/AppIcon.icns" ]]; then
    echo "  [OK] AppIcon.icns bundled in app Resources"
else
    echo "  [FAIL] AppIcon.icns not bundled in DiskHealthMonitor.app"
    exit 1
fi

ICON_PLIST=$(plutil -extract CFBundleIconFile raw "${ROOT_DIR}/DiskHealthMonitor.app/Contents/Info.plist" 2>/dev/null || echo "")
if [[ "${ICON_PLIST}" == "AppIcon" ]]; then
    echo "  [OK] Info.plist CFBundleIconFile is set to AppIcon"
else
    echo "  [FAIL] Info.plist CFBundleIconFile is not set to AppIcon: '${ICON_PLIST}'"
    exit 1
fi

rm -rf "${TEST_SANDBOX_DIR}"

echo "================================================================================"
echo "🎉 ALL TESTS PASSED SUCCESSFULLY!"
echo "================================================================================"
