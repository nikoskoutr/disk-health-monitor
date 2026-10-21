# Section 1: Executive Architecture & Health Scorecard

| Dimension | Score | Detailed Architectural Rationale |
| :--- | :---: | :--- |
| **1. C11 / IOKit Safety & Memory Management** | **7.8 / 10** | `DiskHealthBridge.c` handles `CFRelease` and `IOObjectRelease` well on happy paths and uses `DiskDecodeNVMeLE128` for 128-bit NVMe counters. However, `inspectChildrenForDriverStats` uses `kIORegistryIterateRecursively`, which flattens the subtree into a Depth-First Search iterator; when it encounters an `AppleAPFSContainerScheme`, calling `continue` without `IORegistryIteratorExitEntry` fails to prune the APFS child subtree! Additionally, `findParentBlockStorageDeviceRecursive` can visit diamond-graph APFS nodes redundantly, and `CFStringGetCString` return values are ignored in several places, risking uninitialized/partial buffer reads if encoding conversion fails. |
| **2. Swift Concurrency & Thread Safety** | **6.5 / 10** | Heavy reliance on legacy `NSRecursiveLock`, `NSLock`, and `@unchecked Sendable` across `ConfigManager`, `SecretStore`, `DiskHealthMonitor`, `CanaryProbeService`, and `SurfaceScannerService`. Holding `NSRecursiveLock` (`engineLock`) in `DiskHealthMonitor.evaluateHealth` while invoking `ConfigManager.shared` (`configLock`) and `CanaryProbeService.shared` (`lock`) creates a brittle lock-ordering hierarchy and blocks calling threads during synchronous `fsync()` I/O. `SettingsViewModel` mutates `@Published` properties from non-`@MainActor` contexts and `DispatchWorkItem` callbacks without strict actor isolation. |
| **3. Architectural Cohesion & Separation of Concerns** | **7.0 / 10** | `HealthRules.swift` cleanly separates the 12 evaluation rules, but several rules (`HardwarePresenceRule`, `VolumeMountAndReadOnlyRule`, `CanaryProbeRule`) directly invoke `ConfigManager.shared.log(...)`—violating pure functional evaluation. Furthermore, device discovery (`DiskListAllDevices` + `getfsstat`) is duplicated in **4 separate places** (`TelemetryProvider.swift`, `DiagnosticExporter.swift`, `AppDelegate.swift`, `SettingsViewModel.swift`), causing redundant IOKit bus polling when opening the menu or settings window. |
| **4. Security, Keychain & Secret Masking** | **8.5 / 10** | `SecretStore` implements a well-thought-out opt-in Keychain state machine with `0600` `.secrets.json` fallback that prevents unsolicited macOS Keychain modal popups in headless/daemon contexts, and `SingleInstanceLock` properly enforces `O_NOFOLLOW | O_CLOEXEC`. However, `saveFallbackSecrets` uses `Data.write(to:options:.atomic)` followed by `setAttributes([.posixPermissions: 0o600])`, creating a brief TOCTOU window where the temporary atomic file has default `umask` (`0644`) permissions before `chmod` runs. |
| **5. UI / Menu Bar Performance & Lifecycle** | **7.2 / 10** | `AppDelegate.menuWillOpen` calls `populateSelectDiskMenu()`, which synchronously calls `updateDiskCache()` on the main thread if the cache is empty, stalling menu bar responsiveness during IOKit and `getfsstat` enumeration. `DashboardMenuView` reads `ConfigManager.shared.currentConfig` inside `body` without observing `ConfigManager`, meaning threshold changes in Settings do not immediately re-render the menu bar gauges until the next poll cycle. |
| **6. Testability & Mock Coverage** | **8.2 / 10** | The 15 C unit tests and 35 Swift unit tests provide strong baseline coverage. However, `CanaryProbeService` and `VolumeVerifierService` are coupled as hard singletons inside `DiskHealthMonitor`, preventing `MockTelemetryProvider` from injecting synthetic canary I/O failures, canary high-latency spikes, or volume verification timeouts without touching the real filesystem. |

---

# Section 2: Technical Debt & Systemic Deficiencies Inventory

1. **[C11-01] Unpruned Recursive Iterator into APFS Containers**
   - **Location**: `src/bridge/DiskHealthBridge.c:150-163`
   - **Defect**: `inspectChildrenForDriverStats` creates a recursive iterator (`kIORegistryIterateRecursively`). When `IOIteratorNext(childIter)` yields `AppleAPFSContainerScheme`, `AppleAPFSContainer`, or `AppleAPFSMedia`, the loop simply executes `IOObjectRelease(child); continue;`. Because `kIORegistryIterateRecursively` automatically descends into children on the next `IOIteratorNext` call unless `IORegistryIteratorExitEntry` is used (or manual non-recursive traversal is performed), the iterator still walks every virtual APFS volume, snapshot, and `AppleAPFSMedia` node! Worse, `AppleAPFSMedia` conforms to `IOMedia` and has `Whole = true`, which only avoided overwriting `bsdName` if the physical `IOMedia` happened to be visited first.
   - **Impact**: Unnecessary IOKit kernel calls on systems with many APFS snapshots/volumes and potential misidentification of `bsdName` if registry order varies.

2. **[C11-02] Unchecked `CFStringGetCString` Return Values & String Termination**
   - **Location**: `src/bridge/DiskHealthBridge.c:112-116`, `src/bridge/DiskHealthBridge.c:195-200`
   - **Defect**: In `inspectParentsForBusProperties` and `inspectChildrenForDriverStats`, `CFStringGetCString` is called directly on `outMetrics->serialNumber` and `outMetrics->bsdName` without checking its boolean return value or using the safe `getCFString` helper. If a USB serial number contains non-UTF8 bytes or exceeds buffer length, `outMetrics->serialNumber` can be left in an indeterminate state.
   - **Impact**: Potential garbled C strings crossing the Swift bridge.

3. **[C11-03] Unbounded `getfsstat` Loop & Per-Mount IOKit Lookup in `DiskFindMountForBlockDevice`**
   - **Location**: `src/bridge/DiskHealthBridge.c:447-519`
   - **Defect**: `DiskFindMountForBlockDevice` calls `findBlockStorageDeviceByBSDName(fromName)` inside the `getfsstat` loop for every `/dev/disk*` mount, even if `fromName` does not share the `diskX` prefix or is a synthetic volume. Furthermore, when `maxLen == 1`, `strlcpy(outMountPoint, mountPath, 1)` writes `'\0'` and returns `true` (which Test 10 explicitly asserts: `DiskFindMountForBlockDevice("disk0", oneLenBuf, 1) == true` and `oneLenBuf[0] == '\0'`), so this exact contract must be preserved while optimizing the loop.
   - **Impact**: Redundant IOKit parent tree walks during mount resolution.

4. **[CONC-01] Impure Side Effects (`ConfigManager.shared.log`) Inside Pure `HealthRule` Implementations**
   - **Location**: `src/engine/HealthRules.swift:41`, `src/engine/HealthRules.swift:62`, `src/engine/HealthRules.swift:109`
   - **Defect**: `HardwarePresenceRule`, `VolumeMountAndReadOnlyRule`, and `CanaryProbeRule` call `ConfigManager.shared.log(...)` directly during `evaluate(context:)`.
   - **Impact**: Violates pure functional evaluation of `HealthRule`, performs synchronous disk I/O (`open`/`write`/`close` on `health.log`) while `DiskHealthMonitor` holds `engineLock`, and pollutes logs during unit tests. `HealthRuleOutcome` should instead return `logMessages: [String]` for the engine to log outside the rule pipeline.

5. **[CONC-02] Nested Lock Acquisition Across `DiskHealthMonitor`, `ConfigManager`, and `CanaryProbeService`**
   - **Location**: `src/engine/DiskHealthMonitor.swift:241-462`
   - **Defect**: `DiskHealthMonitor.evaluateHealth` acquires `engineLock.lock()` at line 246 and holds it for the entire duration of hardware IOKit queries, `CanaryProbeService.shared.runCanaryCheck` (which performs `open`, `write`, `fsync`, `unlink`, and `usleep(50_000)` while acquiring its own `lock`), JSON file serialization (`latest_status.json` and `state.json`), and `ConfigManager.shared` calls. Any UI thread reading ` DiskHealthMonitor.shared.currentSnapshot` or `dailySummaryEnabled` blocks waiting on `engineLock` for up to 100ms+ during a canary retry!
   - **Impact**: Main thread micro-stutters when opening the menu bar item while a background poll or canary probe is running.

6. **[ARCH-01] 4x Duplicated Device & Mount Topology Discovery Logic**
   - **Location**:
     1. `src/engine/TelemetryProvider.swift:31-45`
     2. `src/diagnostics/DiagnosticExporter.swift:14-37`
     3. `src/ui/AppDelegate.swift:331-359`
     4. `src/ui/SettingsViewModel.swift:107-149`
   - **Defect**: Four different classes manually allocate `[DiskHardwareMetrics](repeating: ..., count: 16/32)`, call `DiskListAllDevices`, and/or call `getfsstat(nil, 0, MNT_NOWAIT)` to list physical disks and mounted volumes.
   - **Impact**: Violates DRY, bypasses `DiskTelemetryProvider` in `DiagnosticExporter`, `AppDelegate`, and `SettingsViewModel`, and performs redundant IOKit queries.

7. **[SEC-01] Non-Atomic `0600` Permission Window on `.secrets.json` Creation**
   - **Location**: `src/security/SecretStore.swift:355-370`
   - **Defect**: `saveFallbackSecrets` calls `data.write(to: url, options: .atomic)` and only afterwards calls `FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)`. During the atomic temp-file creation and rename window, the file is created with process `umask` (`0644`).
   - **Impact**: Local multi-user race window where `.secrets.json` is world-readable before `chmod(0600)` completes. Writing via a temporary file opened with `open(..., O_CREAT | O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)`, `fchmod(fd, 0o600)`, `fsync(fd)`, `close(fd)`, and `rename(tmpPath, path)` eliminates the race window completely.

8. **[UI-01] Synchronous IOKit & `getfsstat` Blocking on Main Thread in `AppDelegate.populateSelectDiskMenu()`**
   - **Location**: `src/ui/AppDelegate.swift:192-203`
   - **Defect**: When `populateSelectDiskMenu()` is called on the main thread and `cachedDevices` is empty, it synchronously invokes `updateDiskCache()` on the main thread before building the menu.
   - **Impact**: Blocks the AppKit main event loop during IOKit bus enumeration.

9. **[UI-02] `DashboardMenuView` Does Not Observe `ConfigManager` Changes**
   - **Location**: `src/ui/DashboardMenuView.swift:10`
   - **Defect**: `DashboardMenuView` accesses `let cfg = ConfigManager.shared.currentConfig` inside `body`, but only declares `@ObservedObject var monitor: DiskHealthMonitor`.
   - **Impact**: Adjusting temperature warning/critical sliders in Settings does not update the thermal gauge colors or warning labels in `DashboardMenuView` until a new snapshot is published.

10. **[TEST-01] Inability to Inject Synthetic Canary Failures or Volume Verification States via `DiskTelemetryProvider`**
    - **Location**: `src/engine/TelemetryProvider.swift:16-23`, `src/engine/DiskHealthMonitor.swift:294`
    - **Defect**: `DiskHealthMonitor.evaluateHealth` calls `CanaryProbeService.shared.runCanaryCheck(...)` directly instead of routing through `provider.runCanaryProbe(...)`. Consequently, `MockTelemetryProvider` cannot test `CANARY_IO_FAILED` or `CANARY_HIGH_LATENCY` without touching a real filesystem.
    - **Impact**: Incomplete fault-injection capabilities in `MockTelemetryProvider`.

---

# Section 3: Target Unified Architecture Blueprint

## 3.1 Unified Telemetry & Domain Flow

```text
┌────────────────────────────────────────────────────────────────────────────┐
│                        Presentation & Entry Layer                          │
│  • CLI Router (main.swift)                                                 │
│  • AppKit Status Bar Controller (AppDelegate.swift)                        │
│  • SwiftUI Views (DashboardMenuView, SettingsView, 5 Settings Tabs)        │
│  • SettingsViewModel (@MainActor isolated state & debounced persistence)   │
└─────────────────────────────────────┬──────────────────────────────────────┘
                                      │
                                      ▼
┌────────────────────────────────────────────────────────────────────────────┐
│                   Core Engine & Domain Services Layer                      │
│  • DiskHealthMonitor (Fine-grained lock only around in-memory state;       │
│    IOKit & Canary I/O execute outside state lock to prevent UI blocking)   │
│  • StandardHealthRulePipeline (12 Pure Functional HealthRules returning    │
│    HealthRuleOutcome with issues, scorePenalty, and logMessages)           │
│  • DiagnosticExporter (Uses DiskTelemetryProvider for topology discovery)  │
└──────────────┬──────────────────────────────────────────────┬──────────────┘
               │                                              │
               ▼                                              ▼
┌─────────────────────────────────────────┐  ┌───────────────────────────────┐
│      Unified Telemetry Provider         │  │   Security & Config Core      │
│  • DiskTelemetryProvider Protocol       │  │  • ConfigManager              │
│    - readHardwareMetrics(query:)        │  │  • SecretStore (0600 atomic   │
│    - listAllDevices(maxCount:)          │  │    POSIX write + rename)      │
│    - listLocalMountedVolumes()          │  │  • SingleInstanceLock (flock) │
│    - discoverDiskTopology()             │  └───────────────────────────────┘
│    - runCanaryProbe(...)                │
│  • IOKitTelemetryProvider (Live C11)    │
│  • MockTelemetryProvider (Fault Inject) │
└──────────────┬──────────────────────────┘
               │
               ▼
┌────────────────────────────────────────────────────────────────────────────┐
│                    Hardened C11 / IOKit Hardware Bridge                    │
│  • DiskHealthBridge.h / DiskHealthBridge.c                                 │
│  • Explicit non-APFS child tree traversal (pruning APFS containers cleanly)│
│  • Safe CFString / CFNumber / 128-bit NVMe LE extraction                   │
└────────────────────────────────────────────────────────────────────────────┘
```

## 3.2 Key Architectural Upgrades
1. **Pruned IOKit Child Traversal (`DiskHealthBridge.c`)**: Replace the flat `kIORegistryIterateRecursively` child walk in `inspectChildrenForDriverStats` with a bounded recursive walk (`inspectChildrenForDriverStatsRecursive(io_registry_entry_t entry, DiskHardwareMetrics *outMetrics, int depth)`) that immediately returns (pruning the entire branch!) when encountering `AppleAPFSContainerScheme`, `AppleAPFSContainer`, or `AppleAPFSMedia`.
2. **Decoupled Lock-Free I/O in `DiskHealthMonitor`**: Split `currentSnapshot` and `state` protection from slow I/O. Hardware queries, canary probes, and file writes execute without blocking readers of `currentSnapshot` or `isSystemSleeping`, while preserving deterministic thread safety for concurrent callers.
3. **Pure Functional `HealthRule` Pipeline**: Add `var logMessages: [String] = []` to `HealthRuleOutcome` and remove all `ConfigManager.shared.log(...)` side effects from `HealthRules.swift`.
4. **Unified Topology Discovery on `DiskTelemetryProvider`**: Add `listLocalMountedVolumes()` and `discoverTopology(maxDevices:)` to `DiskTelemetryProvider` so `AppDelegate`, `SettingsViewModel`, and `DiagnosticExporter` share a single, testable implementation.
5. **Fault-Injectable Canary & Subpath Probes**: Route canary probing through `DiskTelemetryProvider.runCanaryProbe(targetMount:force:nowTs:)` (defaulting to `CanaryProbeService.shared` in `IOKitTelemetryProvider` and customizable in `MockTelemetryProvider`).
6. **Zero-Race `0600` Secret Persistence**: Upgrade `SecretStore.saveFallbackSecrets` and `ConfigManager.saveSanitizedConfigFile` to write via a mode-`0600` POSIX file descriptor (`O_CREAT | O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC`, `0o600`) + `fchmod(fd, 0o600)` + `fsync(fd)` + atomic `rename()`, eliminating the `umask` race window.

---

# Section 4: Phase-by-Phase Execution Plan for Gemini 3.8 Flash (High)

> **CRITICAL EXECUTOR INSTRUCTIONS FOR GEMINI 3.8 FLASH (HIGH)**:
> Execute the following 5 phases strictly in sequential order. Do NOT skip any step, do NOT alter public function names or CLI flags tested by `tests/run_tests.sh`, and run the verification command at the end of every phase before proceeding to the next phase.

---

## Phase 1: C11 / IOKit Bridge Hardening (`src/bridge/`)

### 1. Objective
Harden `src/bridge/DiskHealthBridge.c` to:
1. Properly prune `AppleAPFSContainerScheme`, `AppleAPFSContainer`, and `AppleAPFSMedia` subtrees during child traversal so virtual APFS nodes and snapshots are never traversed when searching for `IOBlockStorageDriver` statistics and physical whole-disk `IOMedia` BSD names.
2. Use the safe `getCFString` helper consistently when extracting `CFStringRef` properties in `inspectParentsForBusProperties` and `inspectChildrenForDriverStatsRecursive` so buffers are always null-terminated and validated.
3. Prevent redundant IOKit lookups in `findParentBlockStorageDeviceRecursive` and `DiskFindMountForBlockDevice`.

### 2. Affected Files
- Modify: `src/bridge/DiskHealthBridge.c`
- Verify (unchanged header contract): `src/bridge/DiskHealthBridge.h`

### 3. Concrete Interface Contracts & Types
All public C prototypes in `src/bridge/DiskHealthBridge.h` remain 100% unchanged:
```c
void DiskReadHardwareMetrics(const char *targetIdentifier, DiskHardwareMetrics *outMetrics);
int DiskListAllDevices(DiskHardwareMetrics *outArray, int maxCount);
bool DiskFindMountForBlockDevice(const char *deviceBsdName, char *outMountPoint, size_t maxLen);
int32_t DiskConvertNVMeTemperature(uint16_t tempRaw);
uint64_t DiskDecodeNVMeLE128(const uint8_t *bytes);
uint64_t DiskNormalizeLinkSpeedToBps(uint64_t rawSpeed);
uint64_t DiskExtractCFNumberU64(CFDictionaryRef dict, CFStringRef key);
```

Internal static helper in `src/bridge/DiskHealthBridge.c`:
```c
static bool copyCFStringRefToBuffer(CFTypeRef strRef, char *buf, size_t bufLen);
static void inspectChildrenForDriverStatsRecursive(io_registry_entry_t entry, DiskHardwareMetrics *outMetrics, int depth);
```

### 4. Step-by-Step Implementation Instructions
1. Open `src/bridge/DiskHealthBridge.c`.
2. Immediately below `getCFString`, add `copyCFStringRefToBuffer`:
   ```c
   static bool copyCFStringRefToBuffer(CFTypeRef strRef, char *buf, size_t bufLen) {
       if (!strRef || !buf || bufLen == 0) return false;
       if (CFGetTypeID(strRef) != CFStringGetTypeID()) return false;
       if (CFStringGetCString((CFStringRef)strRef, buf, (CFIndex)bufLen, kCFStringEncodingUTF8)) {
           buf[bufLen - 1] = '\0';
           return true;
       }
       buf[0] = '\0';
       return false;
   }
   ```
3. Update `getCFString` to delegate to `copyCFStringRefToBuffer`:
   ```c
   static bool getCFString(CFDictionaryRef dict, CFStringRef key, char *buf, size_t bufLen) {
       if (!dict || !key || !buf || bufLen == 0) return false;
       buf[0] = '\0';
       CFTypeRef val = CFDictionaryGetValue(dict, key);
       return copyCFStringRefToBuffer(val, buf, bufLen);
   }
   ```
4. In `inspectParentsForBusProperties` (`src/bridge/DiskHealthBridge.c`), replace the raw `CFStringGetCString` block for `serialRef` with `copyCFStringRefToBuffer`:
   ```c
   if (serialRef) {
       if (copyCFStringRefToBuffer(serialRef, outMetrics->serialNumber, sizeof(outMetrics->serialNumber))) {
           strlcpy(outMetrics->usbSerialNumber, outMetrics->serialNumber, sizeof(outMetrics->usbSerialNumber));
       }
       CFRelease(serialRef);
   }
   ```
5. Replace `inspectChildrenForDriverStats` in `src/bridge/DiskHealthBridge.c` with a bounded, subtree-pruning recursive traversal `inspectChildrenForDriverStatsRecursive`:
   ```c
   static void inspectChildrenForDriverStatsRecursive(io_registry_entry_t entry, DiskHardwareMetrics *outMetrics, int depth) {
       if (!entry || !outMetrics || depth > 12) return;
       if (outMetrics->statsValid && outMetrics->bsdName[0] != '\0') return;

       io_iterator_t childIter = 0;
       if (IORegistryEntryGetChildIterator(entry, kIOServicePlane, &childIter) != KERN_SUCCESS || !childIter) {
           return;
       }

       io_registry_entry_t child;
       while ((child = IOIteratorNext(childIter)) != 0) {
           // Prune synthesized APFS container subtrees completely so we never descend into
           // virtual AppleAPFSMedia (Whole=true) or virtual container statistics.
           if (IOObjectConformsTo(child, "AppleAPFSContainerScheme") ||
               IOObjectConformsTo(child, "AppleAPFSContainer") ||
               IOObjectConformsTo(child, "AppleAPFSMedia") ||
               IOObjectConformsTo(child, "AppleAPFSVolume")) {
               IOObjectRelease(child);
               continue;
           }

           // Look for Driver Statistics dictionary on IOBlockStorageDriver
           if (!outMetrics->statsValid && IOObjectConformsTo(child, "IOBlockStorageDriver")) {
               CFTypeRef statsRef = IORegistryEntryCreateCFProperty(child, CFSTR("Statistics"), kCFAllocatorDefault, 0);
               if (statsRef) {
                   if (CFGetTypeID(statsRef) == CFDictionaryGetTypeID()) {
                       CFDictionaryRef stats = (CFDictionaryRef)statsRef;
                       outMetrics->statsValid = true;
                       outMetrics->bytesRead = getCFNumberU64(stats, CFSTR("Bytes (Read)"));
                       outMetrics->bytesWritten = getCFNumberU64(stats, CFSTR("Bytes (Write)"));
                       outMetrics->operationsRead = getCFNumberU64(stats, CFSTR("Operations (Read)"));
                       outMetrics->operationsWritten = getCFNumberU64(stats, CFSTR("Operations (Write)"));
                       outMetrics->errorsRead = getCFNumberU64(stats, CFSTR("Errors (Read)"));
                       outMetrics->errorsWritten = getCFNumberU64(stats, CFSTR("Errors (Write)"));
                       outMetrics->retriesRead = getCFNumberU64(stats, CFSTR("Retries (Read)"));
                       outMetrics->retriesWritten = getCFNumberU64(stats, CFSTR("Retries (Write)"));
                       outMetrics->totalTimeReadNs = getCFNumberU64(stats, CFSTR("Total Time (Read)"));
                       outMetrics->totalTimeWriteNs = getCFNumberU64(stats, CFSTR("Total Time (Write)"));
                   }
                   CFRelease(statsRef);
               }
           }

           // Look for physical IOMedia node containing BSD Name (Whole == true and not AppleAPFSMedia)
           if (IOObjectConformsTo(child, "IOMedia") && outMetrics->bsdName[0] == '\0') {
               CFTypeRef wholeRef = IORegistryEntryCreateCFProperty(child, CFSTR("Whole"), kCFAllocatorDefault, 0);
               bool isWhole = false;
               if (wholeRef) {
                   if (CFGetTypeID(wholeRef) == CFBooleanGetTypeID()) {
                       isWhole = CFBooleanGetValue((CFBooleanRef)wholeRef);
                   }
                   CFRelease(wholeRef);
               }

               if (isWhole) {
                   CFTypeRef bsdRef = IORegistryEntryCreateCFProperty(child, CFSTR("BSD Name"), kCFAllocatorDefault, 0);
                   if (bsdRef) {
                       copyCFStringRefToBuffer(bsdRef, outMetrics->bsdName, sizeof(outMetrics->bsdName));
                       CFRelease(bsdRef);
                   }
               }
           }

           if (!(outMetrics->statsValid && outMetrics->bsdName[0] != '\0')) {
               inspectChildrenForDriverStatsRecursive(child, outMetrics, depth + 1);
           }

           IOObjectRelease(child);
           if (outMetrics->statsValid && outMetrics->bsdName[0] != '\0') {
               break;
           }
       }
       IOObjectRelease(childIter);
   }

   static void inspectChildrenForDriverStats(io_registry_entry_t service, DiskHardwareMetrics *outMetrics) {
       inspectChildrenForDriverStatsRecursive(service, outMetrics, 0);
   }
   ```

### 5. Invariants & Guardrails
- Every `IORegistryEntryCreateCFProperty` result MUST be paired with `CFRelease`.
- Every `IOIteratorNext` and `IORegistryEntryGetChildIterator` / `IORegistryEntryGetParentIterator` handle MUST be paired with `IOObjectRelease`.
- Do NOT alter `DiskFindMountForBlockDevice` return semantics for `maxLen == 1` (`strlcpy` writes `'\0'` and returns `true`).
- Must compile cleanly with `-Wall -Wextra` under `clang`.

### 6. Verification Command
Run:
```bash
./build_and_install.sh && ./tests/run_tests.sh
```
Expected result: Zero compiler warnings, all 15 C bridge tests and all 35 Swift unit tests pass.

---

## Phase 2: Security, Atomic `0600` Persistence & Concurrency Hardening (`src/security/`, `src/config/`)

### 1. Objective
1. Eliminate the `umask` (`0644`) TOCTOU race window when writing `.secrets.json` in `SecretStore.swift` and `config.json` in `ConfigManager.swift` by introducing a shared, POSIX-hardened atomic file writer `AtomicFileWriter.writeRestricted(data:toPath:permissions:)` that creates a sibling temporary file using `open(..., O_CREAT | O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, permissions)`, calls `fchmod`, writes all bytes, `fsync`s, closes, and atomically `rename()`s over the target path.
2. Ensure `ConfigManager` and `SecretStore` are strictly `Sendable` and never hold locks while dispatching `objectWillChange` to the main thread.

### 2. Affected Files
- Modify: `src/security/SecretStore.swift`
- Modify: `src/config/ConfigManager.swift`
- Modify: `src/security/SingleInstanceLock.swift`

### 3. Concrete Interface Contracts & Types

Add `AtomicFileWriter` in `src/security/SecretStore.swift`:
```swift
enum AtomicFileWriter {
    @discardableResult
    static func writeRestricted(data: Data, toPath path: String, permissions: mode_t = 0o600) -> Bool {
        let fm = FileManager.default
        let parentDir = (path as NSString).deletingLastPathComponent
        if !parentDir.isEmpty && !fm.fileExists(atPath: parentDir) {
            try? fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parentDir)
        }

        let tmpPath = "\(path).tmp.\(getpid()).\(UUID().uuidString)"
        let fd = open(tmpPath, O_CREAT | O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, permissions)
        guard fd >= 0 else { return false }
        fchmod(fd, permissions)

        let writtenOk: Bool = data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return data.isEmpty }
            var totalWritten = 0
            while totalWritten < data.count {
                let n = Darwin.write(fd, base.advanced(by: totalWritten), data.count - totalWritten)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                totalWritten += n
            }
            return true
        }

        guard writtenOk, fsync(fd) == 0 else {
            close(fd)
            unlink(tmpPath)
            return false
        }
        close(fd)

        if rename(tmpPath, path) != 0 {
            unlink(tmpPath)
            return false
        }
        chmod(path, permissions)
        return true
    }
}
```

### 4. Step-by-Step Implementation Instructions
1. Open `src/security/SecretStore.swift`.
2. Add the `AtomicFileWriter` enum (shown above) at the top of `src/security/SecretStore.swift` (after `import Security` and `import Darwin`).
3. In `SecretStore.saveFallbackSecrets(_ secrets: [String: String]) -> Bool`, replace the `Data.write(to:options:.atomic)` implementation with `AtomicFileWriter.writeRestricted`:
   ```swift
   @discardableResult
   private func saveFallbackSecrets(_ secrets: [String: String]) -> Bool {
       let path = fallbackSecretsPath
       if secrets.isEmpty {
           try? FileManager.default.removeItem(atPath: path)
           return true
       }
       guard let data = try? JSONEncoder().encode(secrets) else {
           return false
       }
       return AtomicFileWriter.writeRestricted(data: data, toPath: path, permissions: 0o600)
   }
   ```
4. Open `src/config/ConfigManager.swift`.
5. Declare `final class ConfigManager: ObservableObject, @unchecked Sendable`.
6. Update `ConfigManager.saveSanitizedConfigFile(_ cfg: DiskHealthConfig, path: String)` to use `AtomicFileWriter.writeRestricted`:
   ```swift
   private static func saveSanitizedConfigFile(_ cfg: DiskHealthConfig, path: String) {
       var sanitized = cfg
       if !sanitized.telegramBotToken.isEmpty {
           if ConfigManager.isRealSecretToken(sanitized.telegramBotToken) {
               _ = SecretStore.shared.setSecret(sanitized.telegramBotToken, forKey: "telegramBotToken", allowInteractiveKeychain: false)
           }
           sanitized.telegramBotToken = "REDACTED_IN_KEYCHAIN"
       }
       if !sanitized.webhookUrl.isEmpty {
           if ConfigManager.isRealSecretToken(sanitized.webhookUrl) {
               _ = SecretStore.shared.setSecret(sanitized.webhookUrl, forKey: "webhookUrl", allowInteractiveKeychain: false)
           }
           sanitized.webhookUrl = "REDACTED_IN_KEYCHAIN"
       }

       let encoder = JSONEncoder()
       encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
       do {
           let data = try encoder.encode(sanitized)
           if !AtomicFileWriter.writeRestricted(data: data, toPath: path, permissions: 0o600) {
               fputs("saveSanitizedConfigFile failed for \(path)\n", stderr)
           }
       } catch {
           fputs("saveSanitizedConfigFile failed for \(path): \(error.localizedDescription)\n", stderr)
       }
   }
   ```
7. In `ConfigManager.swift`, ensure `updateConfig`, `overrideTarget`, and `config.set` release `configLock` BEFORE calling `notifyObjectWillChangeOnMain()` so `objectWillChange.send()` on the main thread always observes the already-updated `_config` value and never contends with `configLock`:
   - In `var config: DiskHealthConfig`:
     ```swift
     set {
         configLock.lock()
         _config = newValue
         configLock.unlock()
         notifyObjectWillChangeOnMain()
     }
     ```
   - In `overrideTarget(volumePath: String?, deviceQuery: String?)`:
     ```swift
     func overrideTarget(volumePath: String?, deviceQuery: String?) {
         configLock.lock()
         var next = self._config
         next.targetVolumePath = volumePath
         next.targetDeviceQuery = deviceQuery
         self._config = next
         configLock.unlock()
         notifyObjectWillChangeOnMain()
     }
     ```
   - In `updateConfig(_ updater: (inout DiskHealthConfig) -> Void)`:
     ```swift
     func updateConfig(_ updater: (inout DiskHealthConfig) -> Void) {
         configLock.lock()
         var next = self._config
         updater(&next)
         SecretStore.shared.useKeychainOptIn = next.useKeychainStorage
         if ConfigManager.isRealSecretToken(next.telegramBotToken) {
             _ = SecretStore.shared.setSecret(next.telegramBotToken, forKey: "telegramBotToken", allowInteractiveKeychain: false)
             self.dotEnvTelegramToken = nil
             next.telegramBotToken = "REDACTED_IN_KEYCHAIN"
         }
         if ConfigManager.isRealSecretToken(next.webhookUrl) {
             _ = SecretStore.shared.setSecret(next.webhookUrl, forKey: "webhookUrl", allowInteractiveKeychain: false)
             self.dotEnvWebhookUrl = nil
             next.webhookUrl = "REDACTED_IN_KEYCHAIN"
         }
         self._config = next
         saveConfigLocked(next)
         configLock.unlock()
         notifyObjectWillChangeOnMain()
     }
     ```
8. Open `src/security/SingleInstanceLock.swift` and mark `final class SingleInstanceLock: @unchecked Sendable`.

### 5. Invariants & Guardrails
- `config.json`, `.secrets.json`, `state.json`, `latest_status.json`, and `health.log` MUST all maintain `0o600` permissions.
- `objectWillChange` on `ConfigManager` MUST only ever fire on `Thread.isMainThread` (verified by Swift Unit Test 12).
- Never trigger interactive macOS Keychain dialogs unless `allowInteractiveKeychain == true`.

### 6. Verification Command
Run:
```bash
./build_and_install.sh && ./tests/run_tests.sh
```
Expected result: All tests pass, including Test 3 (ConfigManager 0600 permissions), Test 12 (Concurrency & MainThread publishing), Test 18 (0600 file permissions), Test 26 (SecretStore thread safety), and Test 35 (Keychain state machine).

---

## Phase 3: Domain Unification, Pure Functional Rules & Lock Decoupling (`src/engine/`, `src/diagnostics/`)

### 1. Objective
1. Make all 12 `HealthRule` structs in `src/engine/HealthRules.swift` 100% pure functions by removing `ConfigManager.shared.log(...)` calls from inside rules and returning `logMessages: [String]` in `HealthRuleOutcome`.
2. Unify disk & mount topology discovery on `DiskTelemetryProvider` (`listLocalMountedVolumes()`, `runCanaryProbe(...)`) so `DiagnosticExporter`, `AppDelegate`, `SettingsViewModel`, and `DiskHealthMonitor` use a single source of truth and `MockTelemetryProvider` can inject synthetic canary probe failures.
3. Use `AtomicFileWriter.writeRestricted` for `state.json`, `latest_status.json`, and exported reports in `DiskHealthMonitor` and `DiagnosticExporter`.

### 2. Affected Files
- Modify: `src/engine/HealthRules.swift`
- Modify: `src/engine/TelemetryProvider.swift`
- Modify: `src/engine/DiskHealthMonitor.swift`
- Modify: `src/diagnostics/DiagnosticExporter.swift`

### 3. Concrete Interface Contracts & Types

In `src/engine/HealthRules.swift`:
```swift
struct HealthRuleOutcome: Sendable {
    var issues: [HealthIssue] = []
    var scorePenalty: Int = 0
    var updatedTemperatureSamples: [(timestamp: TimeInterval, tempC: Int)]? = nil
    var healVerifyFailureToSkipped: Bool = false
    var logMessages: [String] = []
}
```

In `src/engine/TelemetryProvider.swift`:
```swift
struct MountedVolumeInfo: Sendable, Equatable {
    let path: String
    let displayName: String
}

protocol DiskTelemetryProvider: Sendable {
    func readHardwareMetrics(query: String) -> DiskHardwareMetrics
    func listAllDevices(maxCount: Int) -> [DiskHardwareMetrics]
    func listLocalMountedVolumes() -> [MountedVolumeInfo]
    func findMountPoint(forBsdName bsdName: String) -> String?
    func inspectFilesystem(mountPath: String) -> FilesystemMountMetrics
    func checkSubpaths(mountPoint: String, isMounted: Bool, requiredSubpaths: [String]) -> [String: Bool]
    func runCanaryProbe(targetMount: String, force: Bool, nowTs: TimeInterval) -> CanaryProbeResult
    func currentHostThermalState() -> ProcessInfo.ThermalState
}

extension DiskTelemetryProvider {
    func listLocalMountedVolumes() -> [MountedVolumeInfo] {
        return IOKitTelemetryProvider.shared.listLocalMountedVolumes()
    }

    func runCanaryProbe(targetMount: String, force: Bool, nowTs: TimeInterval) -> CanaryProbeResult {
        return CanaryProbeService.shared.runCanaryCheck(targetMount: targetMount, force: force, nowTs: nowTs)
    }
}
```

### 4. Step-by-Step Implementation Instructions
1. **Update `src/engine/HealthRules.swift`**:
   - Add `var logMessages: [String] = []` to `HealthRuleOutcome`.
   - In `HardwarePresenceRule.evaluate(context:)`: replace `ConfigManager.shared.log("Hardware presence not confirmed during wake grace period (8s); suppressing false alert.")` with `outcome.logMessages.append("Hardware presence not confirmed during wake grace period (8s); suppressing false alert.")`.
   - In `VolumeMountAndReadOnlyRule.evaluate(context:)`: replace `ConfigManager.shared.log("Volume unmounted status during wake grace period (8s); suppressing false alert.")` with `outcome.logMessages.append("Volume unmounted status during wake grace period (8s); suppressing false alert.")`.
   - In `CanaryProbeRule.evaluate(context:)`: replace `ConfigManager.shared.log("Canary probe issue suppressed during wake grace period (8s).")` with `outcome.logMessages.append("Canary probe issue suppressed during wake grace period (8s).")`.

2. **Update `src/engine/TelemetryProvider.swift`**:
   - Add `struct MountedVolumeInfo: Sendable, Equatable` with `let path: String` and `let displayName: String`.
   - Update `protocol DiskTelemetryProvider` and add the default protocol extension for `listLocalMountedVolumes()` and `runCanaryProbe(targetMount:force:nowTs:)`.
   - Implement `listLocalMountedVolumes()` and `runCanaryProbe(targetMount:force:nowTs:)` on `IOKitTelemetryProvider`:
     ```swift
     func listLocalMountedVolumes() -> [MountedVolumeInfo] {
         var mounts: [MountedVolumeInfo] = []
         let numMounts = getfsstat(nil, 0, MNT_NOWAIT)
         guard numMounts > 0 else { return mounts }
         let allocCount = Int(numMounts) + 4
         var fsList = Array<Darwin.statfs>(repeating: Darwin.statfs(), count: allocCount)
         let mCount = getfsstat(&fsList, Int32(MemoryLayout<Darwin.statfs>.size * allocCount), MNT_NOWAIT)
         guard mCount > 0 else { return mounts }
         for i in 0..<min(Int(mCount), allocCount) {
             let volPath = cStringToSwift(fsList[i].f_mntonname)
             let flags = UInt32(fsList[i].f_flags)
             let isLocal = (flags & UInt32(MNT_LOCAL)) != 0
             if isLocal && (volPath.hasPrefix("/Volumes/") || volPath == "/") {
                 let displayName = volPath == "/" ? "Macintosh HD (/)" : (volPath as NSString).lastPathComponent
                 mounts.append(MountedVolumeInfo(path: volPath, displayName: displayName))
             }
         }
         return mounts
     }

     func runCanaryProbe(targetMount: String, force: Bool, nowTs: TimeInterval) -> CanaryProbeResult {
         return CanaryProbeService.shared.runCanaryCheck(targetMount: targetMount, force: force, nowTs: nowTs)
     }
     ```
   - In `MockTelemetryProvider`:
     - Add properties:
       ```swift
       var mountedVolumes: [MountedVolumeInfo] = []
       var canaryResultOverride: CanaryProbeResult? = nil
       ```
     - Implement `listLocalMountedVolumes()` and `runCanaryProbe(targetMount:force:nowTs:)`:
       ```swift
       func listLocalMountedVolumes() -> [MountedVolumeInfo] {
           lock.lock()
           defer { lock.unlock() }
           return mountedVolumes
       }

       func runCanaryProbe(targetMount: String, force: Bool, nowTs: TimeInterval) -> CanaryProbeResult {
           lock.lock()
           let override = canaryResultOverride
           lock.unlock()
           if let override = override {
               return override
           }
           return CanaryProbeService.shared.runCanaryCheck(targetMount: targetMount, force: force, nowTs: nowTs)
       }
       ```

3. **Update `src/engine/DiskHealthMonitor.swift`**:
   - Mark `final class DiskHealthMonitor: ObservableObject, @unchecked Sendable`.
   - In `evaluateHealth`, replace `CanaryProbeService.shared.runCanaryCheck(targetMount: fsMetrics.mountPoint, force: forceCanary, nowTs: nowTs)` with:
     ```swift
     let res = provider.runCanaryProbe(targetMount: fsMetrics.mountPoint, force: forceCanary, nowTs: nowTs)
     ```
   - In the rule evaluation loop inside `evaluateHealth`:
     ```swift
     for rule in StandardHealthRulePipeline.defaultRules {
         let outcome = rule.evaluate(context: evaluationContext)
         for msg in outcome.logMessages {
             ConfigManager.shared.log(msg)
         }
         issues.append(contentsOf: outcome.issues)
         score -= outcome.scorePenalty
         if let updatedTemps = outcome.updatedTemperatureSamples {
             recentTemperatureSamples[driveKey] = updatedTemps
         }
         if outcome.healVerifyFailureToSkipped {
             state.updateDriveState(key: driveKey) {
                 $0.lastVerifyOk = true
                 if !$0.lastVerifyResult.starts(with: "Skipped") {
                     $0.lastVerifyResult = "Skipped: Requires administrator privileges (-69863)"
                 }
             }
             driveState.lastVerifyOk = true
         }
     }
     ```
   - In `saveStateLocked()` and `evaluateHealth` (where `latest_status.json` is written) and `loadState()` (where migrated `state.json` is written), use `AtomicFileWriter.writeRestricted(data: ..., toPath: ..., permissions: 0o600)`.

4. **Update `src/diagnostics/DiagnosticExporter.swift`**:
   - Mark `final class DiagnosticExporter: @unchecked Sendable`.
   - In `generateDiagnosticReport(snapshot: DiskHealthSnapshot? = nil)`: replace the manual `DiskListAllDevices` + `DiskFindMountForBlockDevice` C array boilerplate with `IOKitTelemetryProvider.shared`:
     ```swift
     let rawDevices = IOKitTelemetryProvider.shared.listAllDevices(maxCount: 32)
     var detectedDevicesList: [[String: Any]] = []
     for d in rawDevices {
         let bsd = cStringToSwift(d.bsdName)
         let mountPath = IOKitTelemetryProvider.shared.findMountPoint(forBsdName: bsd) ?? ""
         detectedDevicesList.append([
             "bsdName": bsd,
             "vendorName": cStringToSwift(d.vendorName),
             "productName": cStringToSwift(d.productName),
             "serialNumber": cStringToSwift(d.serialNumber),
             "interconnectType": cStringToSwift(d.interconnectType),
             "protocolType": cStringToSwift(d.protocolType),
             "isInternal": d.isInternal,
             "isRemovable": d.isRemovable,
             "linkSpeedBps": d.linkSpeedBps,
             "smartValid": d.smartValid,
             "temperatureCelsius": d.temperatureCelsius,
             "mountPoint": mountPath
         ])
     }
     ```
   - In `saveDiagnosticReportToFile` and `saveDiagnosticReportHTMLToFile`, use `AtomicFileWriter.writeRestricted(data: data, toPath: targetPath, permissions: 0o600)`.

### 5. Invariants & Guardrails
- `DiskHealthMonitor.evaluateHealth` signature and default parameters (`forceCanary: Bool = false, allowNotifications: Bool = true, telemetryProvider: (any DiskTelemetryProvider)? = nil`) MUST remain identical.
- When `telemetryProvider` is `nil` (or when `MockTelemetryProvider.canaryResultOverride` is `nil`), `runCanaryProbe` MUST still execute `CanaryProbeService.shared.runCanaryCheck(...)` so existing tests that test real canary probes continue to work identically.

### 6. Verification Command
Run:
```bash
./build_and_install.sh && ./tests/run_tests.sh
```
Expected result: All 15 C tests, 35 Swift tests, and CLI stages pass.

---

## Phase 4: Menu Bar & UI Responsiveness Overhaul (`src/ui/`)

### 1. Objective
1. Eliminate duplicate `DiskListAllDevices` and `getfsstat` code in `AppDelegate.swift` and `SettingsViewModel.swift` by using `IOKitTelemetryProvider.shared.listAllDevices(maxCount: 16)` and `IOKitTelemetryProvider.shared.listLocalMountedVolumes()`.
2. Prevent `AppDelegate.menuWillOpen` from blocking the main thread on uncached IOKit queries while preserving synchronous behavior for unit tests (`Test 31e` calls `appDelegate.populateSelectDiskMenu()` directly without opening the menu).
3. Observe `ConfigManager` in `DashboardMenuView` so threshold slider updates in Settings immediately reflect in the menu bar dashboard card.

### 2. Affected Files
- Modify: `src/ui/AppDelegate.swift`
- Modify: `src/ui/DashboardMenuView.swift`
- Modify: `src/ui/SettingsViewModel.swift`

### 3. Concrete Interface Contracts & Types

In `src/ui/DashboardMenuView.swift`:
```swift
struct DashboardMenuView: View {
    @ObservedObject var monitor: DiskHealthMonitor
    @ObservedObject var configMgr: ConfigManager = ConfigManager.shared
    ...
}
```

### 4. Step-by-Step Implementation Instructions
1. **Update `src/ui/DashboardMenuView.swift`**:
   - Add `@ObservedObject var configMgr: ConfigManager = ConfigManager.shared` to `DashboardMenuView` (giving it a default value so existing `DashboardMenuView(monitor: DiskHealthMonitor.shared)` call sites require no changes).
   - Replace `let cfg = ConfigManager.shared.currentConfig` inside `var body: some View` with `let cfg = configMgr.config`.

2. **Update `src/ui/AppDelegate.swift`**:
   - Replace `private var cachedMounts: [(path: String, name: String)] = []` with `private var cachedMounts: [MountedVolumeInfo] = []`.
   - Simplify `updateDiskCache()` to delegate to `IOKitTelemetryProvider.shared`:
     ```swift
     private func updateDiskCache() {
         let devices = IOKitTelemetryProvider.shared.listAllDevices(maxCount: 16)
         let mounts = IOKitTelemetryProvider.shared.listLocalMountedVolumes()
         cacheLock.lock()
         cachedDevices = devices
         cachedMounts = mounts
         cacheLock.unlock()
     }
     ```
   - In `populateSelectDiskMenu()`, update the `for m in mounts` loop to use `m.displayName` and `m.path` (instead of `m.name` and `m.path`).
   - In `applicationDidFinishLaunching`, pre-warm `updateDiskCache()` asynchronously via `refreshHealth(forceCanary: true)` (already present) so `cachedDevices` and `cachedMounts` are populated before the user clicks the menu bar icon.

3. **Update `src/ui/SettingsViewModel.swift`**:
   - Simplify `refreshDiskList()` to use `IOKitTelemetryProvider.shared`:
     ```swift
     func refreshDiskList() {
         DispatchQueue.global(qos: .userInitiated).async {
             var items: [(id: String, name: String)] = []
             let devices = IOKitTelemetryProvider.shared.listAllDevices(maxCount: 16)
             for d in devices {
                 let prod = cStringToSwift(d.productName)
                 let vendor = cStringToSwift(d.vendorName)
                 let bsd = cStringToSwift(d.bsdName)
                 let bus = cStringToSwift(d.interconnectType)
                 let label = "\(vendor.isEmpty ? "" : vendor + " ")\(prod) (\(bsd), \(bus))"
                 items.append((id: bsd, name: label))
             }

             let mounts = IOKitTelemetryProvider.shared.listLocalMountedVolumes()
             for m in mounts {
                 items.append((id: m.path, name: "📂 \(m.displayName) (\(m.path))"))
             }

             let cfg = ConfigManager.shared.currentConfig
             if let customVol = cfg.targetVolumePath, !customVol.isEmpty,
                !items.contains(where: { $0.id == customVol }) {
                 items.append((id: customVol, name: "📌 Configured Volume (\(customVol))"))
             }
             if let customDev = cfg.targetDeviceQuery, !customDev.isEmpty,
                !items.contains(where: { $0.id == customDev }) {
                 items.append((id: customDev, name: "📌 Configured Device (\(customDev))"))
             }
             DispatchQueue.main.async {
                 self.availableDisks = items
             }
         }
     }
     ```
   - In `exportConfigAction()`, use `AtomicFileWriter.writeRestricted`:
     ```swift
     if let data = json.data(using: .utf8),
        AtomicFileWriter.writeRestricted(data: data, toPath: url.path, permissions: 0o600) {
         diagnosticsStatusMsg = "Saved configuration to \(url.lastPathComponent)"
     } else {
         diagnosticsStatusMsg = "Failed to save configuration."
     }
     ```

### 5. Invariants & Guardrails
- `AppDelegate.populateSelectDiskMenu()` MUST still populate `selectDiskMenu` synchronously when called directly in unit tests (`Test 31e` creates `AppDelegate()`, sets a test `NSMenu` via `testingSetSelectDiskMenu`, and immediately calls `populateSelectDiskMenu()`). Keeping the `if devices.isEmpty && mounts.isEmpty { updateDiskCache() ... }` fallback inside `populateSelectDiskMenu()` guarantees `Test 31e` passes while live app launches pre-populate the cache in `refreshHealth`.
- `AppDelegate.shouldProcessVolumeNotification(volumePath:)` and `SettingsViewModel.makeLaunchAgentPlistDict(bundleId:binaryPath:logsDir:)` signatures MUST remain untouched.

### 6. Verification Command
Run:
```bash
./build_and_install.sh && ./tests/run_tests.sh
```
Expected result: Zero warnings, all unit and CLI tests pass.

---

## Phase 5: Test Harness Expansion & Synthetic Fault Injection (`tests/`)

### 1. Objective
Expand the automated test suite in `tests/test_core_logic.swift` with **Test 36** to validate:
1. Synthetic Canary I/O fault injection (`CANARY_IO_FAILED` and `CANARY_HIGH_LATENCY`) via `MockTelemetryProvider.canaryResultOverride` without touching physical disks.
2. Pure functional `HealthRuleOutcome.logMessages` generation during wake grace period suppression without triggering side-effect disk writes inside `HealthRule.evaluate(context:)`.
3. `AtomicFileWriter.writeRestricted` `0600` permission enforcement and symlink rejection (`O_NOFOLLOW`).
4. `IOKitTelemetryProvider.shared.listLocalMountedVolumes()` topology discovery.

### 2. Affected Files
- Modify: `tests/test_core_logic.swift`

### 3. Concrete Interface Contracts & Types
No new production types required; uses `MockTelemetryProvider.canaryResultOverride`, `AtomicFileWriter.writeRestricted`, `HealthRuleOutcome.logMessages`, and `IOKitTelemetryProvider.shared.listLocalMountedVolumes()` introduced in Phases 2–4.

### 4. Step-by-Step Implementation Instructions
1. Open `tests/test_core_logic.swift`.
2. Immediately after the `Test 35` block (and before `print("✅ All Swift Core Logic Unit Tests Passed!")`), add **Swift Unit Test 36**:
   ```swift
        // Test 36: Synthetic Canary Fault Injection, Pure Rule Log Outcomes & AtomicFileWriter (Phase 5 Overhaul)
        print("\n=== Swift Unit Test 36: Synthetic Canary Fault Injection, Pure Rule Outcomes & AtomicFileWriter ===")
        do {
            let origConfig = ConfigManager.shared.currentConfig
            defer {
                ConfigManager.shared.updateConfig { $0 = origConfig }
                monitor.resetBaselines()
            }

            ConfigManager.shared.updateConfig {
                $0.targetVolumePath = "/Volumes/MockCanaryDrive"
                $0.targetDeviceQuery = "disk42"
                $0.enableActiveCanary = true
                $0.minExpectedUsbSpeedBps = 0
            }
            monitor.resetBaselines()
            monitor.noteSystemDidWake(at: Date().timeIntervalSince1970 - 30.0)

            let mockMount = FilesystemMountMetrics(
                isMounted: true,
                mountPoint: "/Volumes/MockCanaryDrive",
                filesystemType: "apfs",
                isReadOnly: false,
                totalBytes: 1_000_000_000_000,
                freeBytes: 800_000_000_000,
                purgeableBytes: 0,
                usedBytes: 200_000_000_000,
                usedPercent: 20.0
            )

            // 36a. Synthetic CANARY_IO_FAILED via MockTelemetryProvider
            let mockCanaryFail = MockTelemetryProvider()
            mockCanaryFail.mountPointByBsd["disk42"] = "/Volumes/MockCanaryDrive"
            mockCanaryFail.filesystemMetrics = mockMount
            mockCanaryFail.hardwareMetrics = makeMockDiskHardwareMetrics()
            mockCanaryFail.canaryResultOverride = CanaryProbeResult(ok: false, latencyMs: 0.0, error: "Synthetic EIO fsync error")

            let snapCanaryFail = monitor.evaluateHealth(forceCanary: true, allowNotifications: false, telemetryProvider: mockCanaryFail)
            assertTrue(snapCanaryFail.overallSeverity == .critical, "Synthetic canary failure must trigger CRITICAL severity")
            assertTrue(snapCanaryFail.issues.contains(where: { $0.code == "CANARY_IO_FAILED" }), "Must report CANARY_IO_FAILED issue")
            assertTrue(snapCanaryFail.canaryError == "Synthetic EIO fsync error", "Snapshot must preserve synthetic canary error string")

            // 36b. Synthetic CANARY_HIGH_LATENCY (> 300ms) via MockTelemetryProvider
            let mockCanarySlow = MockTelemetryProvider()
            mockCanarySlow.mountPointByBsd["disk42"] = "/Volumes/MockCanaryDrive"
            mockCanarySlow.filesystemMetrics = mockMount
            mockCanarySlow.hardwareMetrics = makeMockDiskHardwareMetrics()
            mockCanarySlow.canaryResultOverride = CanaryProbeResult(ok: true, latencyMs: 450.5, error: "")

            let snapCanarySlow = monitor.evaluateHealth(forceCanary: true, allowNotifications: false, telemetryProvider: mockCanarySlow)
            assertTrue(snapCanarySlow.overallSeverity == .warning, "High canary latency (450.5ms > 300ms) must trigger WARNING severity")
            assertTrue(snapCanarySlow.issues.contains(where: { $0.code == "CANARY_HIGH_LATENCY" }), "Must report CANARY_HIGH_LATENCY issue")

            // 36c. Pure functional HealthRuleOutcome logMessages verification during wake grace period
            let wakeCtx = HealthEvaluationContext(
                nowTs: 2000,
                config: ConfigManager.shared.currentConfig,
                hardware: makeMockDiskHardwareMetrics(found: false),
                linkSpeedFormatted: "USB",
                interconnect: "USB",
                mountToInspect: "/Volumes/MockCanaryDrive",
                filesystem: FilesystemMountMetrics(isMounted: false),
                subpathsStatus: [:],
                canaryOk: false,
                canaryLatencyMs: 0.0,
                canaryError: "Failed",
                avgReadLatMs: 0.0,
                avgWriteLatMs: 0.0,
                inWakeGrace: true,
                hostThermalState: .nominal,
                driveState: DriveBaselineState(),
                recentTemperatureSamples: []
            )
            let hwRuleOutcome = HardwarePresenceRule().evaluate(context: wakeCtx)
            assertTrue(hwRuleOutcome.issues.isEmpty, "HardwarePresenceRule must suppress issue during wake grace")
            assertTrue(!hwRuleOutcome.logMessages.isEmpty, "HardwarePresenceRule must emit pure logMessages in outcome")

            // 36d. AtomicFileWriter 0600 permissions & symlink overwrite protection
            let atomicTestPath = "\(NSTemporaryDirectory())atomic_writer_test_\(UUID().uuidString).json"
            let payloadData = Data("{\"test\":true}".utf8)
            assertTrue(AtomicFileWriter.writeRestricted(data: payloadData, toPath: atomicTestPath, permissions: 0o600), "AtomicFileWriter must succeed")
            if let attrs = try? FileManager.default.attributesOfItem(atPath: atomicTestPath),
               let perms = attrs[.posixPermissions] as? NSNumber {
                assertTrue(perms.intValue == 0o600, "AtomicFileWriter must enforce 0600 permissions")
            } else {
                assertTrue(false, "Failed to inspect AtomicFileWriter file permissions")
            }
            try? FileManager.default.removeItem(atPath: atomicTestPath)

            // 36e. Unified listLocalMountedVolumes verification
            let localVolumes = IOKitTelemetryProvider.shared.listLocalMountedVolumes()
            assertTrue(localVolumes.contains(where: { $0.path == "/" }), "listLocalMountedVolumes must include root volume '/'")
            print("  [OK] Synthetic canary fault injection, pure rule log outcomes, and AtomicFileWriter verified")
        }
   ```

### 5. Invariants & Guardrails
- Always restore `ConfigManager.shared` and `DiskHealthMonitor.shared.resetBaselines()` at the end of the test block using `defer`.
- All 5 stages in `./tests/run_tests.sh` must complete with zero failures.

### 6. Verification Command
Run:
```bash
./build_and_install.sh && ./build_and_install.sh --test
```
Expected result:
- `test_disk_health_bridge`: All 15 C/IOKit unit tests pass.
- `test_core_logic`: All 36 Swift core logic & synthetic fault injection unit tests pass.
- CLI binary stages 3, 4, and 5 pass with `🎉 ALL TESTS PASSED SUCCESSFULLY!`.
