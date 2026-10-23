# Architectural Review, Code Readability Mandate & Master Blueprint (`v2.4.0 Build 7`)

**Author:** Gemini 4 Argon (Lead Systems Architect & Principal Code Reviewer)  
**Target Executor:** Gemini 3.8 Flash (High Thinking Mode)  
**Repository:** `Universal Disk Health Monitor` (`v2.4.0`, Build 7, Darwin/macOS `arm64` & `x86_64`)  
**Baseline Status:** 15/15 C Bridge Tests Passing, 40/40 Swift Core Engine Tests Passing, 5/5 CLI Integration Stages Passing.

---

# Part 1: Principal Code Review — Coherence, Consistency & Human Readability

Following 12 rounds of hardening and the Pass 1/Pass 2 multi-disk unification, the runtime behavior, memory safety, and concurrency mechanics of the codebase are production-grade. However, **human maintainability and inline architectural documentation lag behind the sophistication of the code**. Crucial kernel invariants, lock-hierarchy rules, hardware workarounds, and POSIX edge cases currently live only in commit messages or test assertions rather than directly in the source files where future systems engineers will read them.

## 1.1 Layer-by-Layer Readability & Documentation Gap Analysis

### Layer 1: C11 / IOKit Hardware Bridge (`src/bridge/DiskHealthBridge.h`, `src/bridge/DiskHealthBridge.c`)
- **Undocumented Kernel & Hardware Invariants**:
  1. **`sStaticCache` Partial Restoration (`UAT2-03`)**: In `populateMetricsFromBlockStorageDevice`, `sStaticCache` caches invariant device strings (`productName`, `vendorName`, `serialNumber`, `interconnectType`, `linkSpeedBps`), **deliberately omitting `bsdName` on cache hit** so `inspectChildrenForDriverStats` always queries the live `IOMedia` child node. Without an explicit comment explaining *why* `slot->bsdName` is stored but not restored on cache hit, a future maintainer might "fix" the perceived omission and re-introduce the stale BSD name bug after hot-swap!
  2. **APFS Subtree Pruning (`C11-01`)**: `inspectChildrenForDriverStatsRecursive` prunes `AppleAPFSContainerScheme`, `AppleAPFSContainer`, `AppleAPFSMedia`, and `AppleAPFSVolume`. Needs a clear block comment explaining that `AppleAPFSMedia` also sets `Whole = true` in IOKit, which would clobber the physical disk's `bsdName` (`disk0` -> `disk3`) if not pruned.
  3. **Bus Precedence (`SYS-06`)**: In `inspectParentsForBusProperties`, USB and Thunderbolt parent nodes overwrite `interconnectType` even if a child NVMe/PCIe bridge was seen first (e.g., Thunderbolt NVMe enclosures have an internal PCIe bridge inside an external Thunderbolt tunnel). This invariant must be documented inline.
  4. **128-bit NVMe Counter Units**: In `DiskHealthBridge.h`, `dataUnitsRead` and `dataUnitsWritten` should document the NVMe Base Specification 1.4+ definition (1 Data Unit = 1,000 × 512-byte sectors = 512,000 bytes).

### Layer 2: Core Engine & Services (`src/engine/*.swift`)
- **Undocumented Concurrency & Filesystem Invariants**:
  1. **Lock Ordering & Priority Inversion Avoidance (`SYS2-02`)**: `DiskHealthMonitor.selectDashboardDrive(key:)` updates `@Published` properties immediately on the main thread and dispatches `engineLock` acquisition asynchronously to `DispatchQueue.global(qos: .userInitiated)`. This critical pattern prevents the main UI thread from blocking behind a background poll holding `engineLock` during `statfs` or `fsync`. It requires an explicit `/// - Concurrency:` docblock.
  2. **Sector-Aligned `F_NOCACHE` & Self-Healing (`UAT2-01`, `UAT2-04`)**: `CanaryProbeService.performSingleCanaryPass` pads its buffer to 512 bytes and retries without `F_NOCACHE` on `EINVAL`. Why? Because macOS `msdosfs` (FAT32) and `exfat` kernel drivers reject unaligned `F_NOCACHE` `pwrite`/`pread` calls with `EINVAL`. Furthermore, the `EACCES`/`EPERM` `unlink()` self-healing retry preserves `openErrno` so read-only mounts don't overwrite the error code with `ENOENT`. Both require clear inline comments.
  3. **Grandchild Process Tree Termination (`SYS2-05`)**: `VolumeVerifierService.terminateProcessAndChildren` invokes `/usr/bin/pkill -P <pid>` before `kill(pid, sig)` and closes `readHandle` in the watchdog escalation block. Why? Because `diskutil verifyVolume` spawns `fsck_apfs`, which inherits the stdout/stderr pipe file descriptors; if only `diskutil` is killed, `readHandle.readToEnd()` hangs until `fsck_apfs` exits.

### Layer 3: Security, Config & Persistence (`src/security/*.swift`, `src/config/ConfigManager.swift`)
- **Undocumented Security State Machines**:
  1. **Zero-Popup Keychain Opt-In (`SecretStore`)**: `SecretStore` must clearly document its core security contract at the class header level: *Headless CLI commands and background LaunchAgent polls (`allowInteractiveKeychain == false`) NEVER call `SecItemCopyMatching` or `SecItemAdd` unless opted in and explicitly triggered, preventing unprompted macOS `securityd` modal dialogs from blocking unattended execution.*
  2. **Zero-Window `0600` Atomic Persistence (`AtomicFileWriter`)**: Document why `Foundation`'s `Data.write(to:options:.atomic)` was replaced (it creates the temporary file with default `umask` `0644` before `chmod`, creating a local multi-user TOCTOU read window).

### Layer 4: Diagnostics, Notifications & Presentation (`src/diagnostics/`, `src/notifications/`, `src/ui/`, `src/main.swift`)
- **Undocumented Tricks & Boundaries**:
  1. **Reverse-Seek Log Tailer (`SYS2-01`)**: `DiagnosticExporter.readLastLogLines` reads `maxTailBytes + 1` bytes and checks `buffer[0] != UInt8(ascii: "\n")` when `offset > 0` to deterministically discard partial leading lines (including split multi-byte UTF-8 sequences).
  2. **Double-Fork / `POSIX_SPAWN_SETSID` Detachment (`src/main.swift`)**: `ensureRunningFromAppBundleIfAvailable()` and `detachFromControllingTerminalIfNeeded()` use `posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))` so launching `./disk-health` from an interactive terminal detaches the Menu Bar agent into a new session leader without a controlling TTY.

---

## 1.2 Mandatory Documentation & Coding Standards

To make the codebase exemplary, coherent, and self-documenting, the executing agent (**Gemini 3.8 Flash High**) must apply the following standards:

### 1. File Header Banners
Every `.h`, `.c`, and `.swift` file in `src/` must begin with a standardized 8-line architectural header banner:
```swift
// ============================================================================
// File: <Filename>
// Module: <Layer / Subsystem Name>
// Purpose: <Concise 1-2 sentence description of architectural responsibility>
// Concurrency: <Sendable / Lock / MainActor isolation model>
// ============================================================================
```

### 2. Doxygen (C11) & Swift DocC (`///`) Standards
- **C11 Functions (`DiskHealthBridge.h` & `.c`)**: Use `@brief`, `@param`, `@return`, and `@note` (specifically noting CoreFoundation/IOKit reference ownership rules: *"Caller is responsible for releasing returned `io_service_t` via `IOObjectRelease`"*).
- **Swift Types & Public/Internal Methods**: Use triple-slash `///` Swift DocC comments with `- Parameters:`, `- Returns:`, and `- Important:` or `- Note:` callouts for thread-safety and lock preconditions (e.g., `/// - Precondition: Must be called with \`engineLock\` held.`).

### 3. Standardized `// MARK: -` Section Organization
Every Swift file exceeding 100 lines must organize its declarations using consistent `// MARK: -` dividers:
- `// MARK: - Types & Constants`
- `// MARK: - Properties & Synchronization`
- `// MARK: - Lifecycle & Initialization`
- `// MARK: - Public API`
- `// MARK: - Internal & Private Helpers`

### 4. Strict Non-Regression Rule for Code Comments
> **CRITICAL GUARDRAIL FOR EXECUTOR**: When adding comments, docblocks, and section markers across `src/`, **do NOT alter any executable logic, method signatures, struct layouts, or string literals**. All 15 C tests, 40 Swift tests, and 5 CLI integration stages must pass with 0 warnings after commenting.

---

# Part 2: Master Architectural Blueprint (`docs/ARCHITECTURE.md`)

As Lead Architect, I recommend combining two industry-standard architectural frameworks in `docs/ARCHITECTURE.md`:
1. **arc42 Architectural Template** (Sections 1 through 12): Provides the structural backbone used in mission-critical systems engineering.
2. **C4 Model-as-Code (via Mermaid)**: Embeds version-controlled, executable **System Context (C1)**, **Container (C2)**, **Component (C3)**, and **Code/Class (C4)** diagrams alongside **UML Runtime Sequence Diagrams** and **State Machines** directly in Markdown.

Below is the complete, authoritative specification for `docs/ARCHITECTURE.md`.

---

## Blueprint Structure for `docs/ARCHITECTURE.md`

### Section 1: Introduction and Goals
- **System Purpose**: Zero-dependency macOS hardware storage telemetry daemon, interactive Menu Bar monitor, and CLI utility supporting internal Apple Silicon (`arm64`) / Intel (`x86_64`) NVMe SSDs and external USB, Thunderbolt, and SATA enclosures.
- **Core Quality Attributes (ISO/IEC 25010)**:
  1. **Resource Efficiency**: `< 0.1%` average CPU overhead during 30s background polling; `< 25 MB` Resident Set Size (RSS) in daemon mode via ephemeral Settings window deallocation (`OPT2-03`) and static IOKit registry caching (`OPT-01`).
  2. **Reliability & Fault Tolerance**: Non-destructive sector-aligned canary probes (`F_NOCACHE`), 8-second dark-wake hardware settle grace periods, and two-stage subprocess watchdogs (`SIGTERM` -> `SIGKILL` with child process group cleanup via `pkill -P`).
  3. **Security**: Zero unprompted Keychain modal popups in headless/daemon contexts; race-free `0600` POSIX file creation (`O_CREAT | O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC`); automatic token/webhook redaction across all logs and diagnostic exports.

### Section 2: Architecture Constraints
| Constraint | Technical Details & Rationale |
| :--- | :--- |
| **Zero Third-Party Dependencies** | Compiled strictly against Apple system frameworks (`IOKit`, `CoreFoundation`, `Security`, `UserNotifications`, `AppKit`, `SwiftUI`) and POSIX/Darwin libc. |
| **Standalone `clang` + `swiftc` Build** | Built directly via `build_and_install.sh` without Xcode project files or Swift Package Manager plugins. Prohibits Swift 5.9+ macro-backed wrappers (`@Observable`) that require external compiler plugin binaries. |
| **Single-Binary Dual-Mode Execution** | One universal Mach-O executable (`DiskHealthMonitor.app/Contents/MacOS/DiskHealthMonitor` + `disk-health` symlink) serves both as a headless CLI tool and an `LSUIElement` AppKit Menu Bar agent. |
| **OS & Architecture Target** | macOS 13.0 (Ventura) through macOS 15+ (Sequoia); Universal Binary (`arm64` + `x86_64`) compiled with `-whole-module-optimization` and `-Xlinker -dead_strip`. |

### Section 3: System Scope and Context (C4 Level 1 — System Context)
```mermaid
flowchart TB
    User["👤 macOS User / Systems Admin<br/>(Menu Bar UI & Interactive CLI)"]
    Launchd["⚙️ macOS launchd<br/>(GUI LaunchAgent & Mount Watcher)"]
    DHM["🛡️ Universal Disk Health Monitor<br/>(Single Binary: C11 Bridge + Swift Engine + AppKit/SwiftUI)"]
    Kernel["🍎 Darwin Kernel & IOKit<br/>(IONVMeSMARTUserClient, IOBlockStorageDriver, statfs, POSIX VFS)"]
    DiskU["🔧 /usr/sbin/diskutil<br/>(Child Process: verifyVolume / fsck_apfs)"]
    Keychain["🔐 macOS Security.framework<br/>(System Keychain & Local 0600 Store)"]
    Notif["🔔 Alert Destinations<br/>(macOS Notification Center, Telegram Bot API, Discord/Slack/HA Webhooks, Custom Shell Hook)"]

    User -->|"CLI flags (--status, --all, --json) / Menu Bar (⌘, ⌘I ⌘S)"| DHM
    Launchd -->|"Spawns & supervises (--menubar)"| DHM
    DHM -->|"Mach ports, IORegistry, F_NOCACHE I/O"| Kernel
    DHM -->|"Spawns with 180s watchdog"| DiskU
    DHM -->|"Opt-in SecItemCopyMatching / 0600 file"| Keychain
    DHM -->|"HTTPS POST / UNNotificationRequest / posix_spawn"| Notif
```

### Section 4: Solution Strategy & Container View (C4 Level 2 — Container View)
- **Dual-Mode Process Bootstrap**:
  - Invoking with CLI flags (`--status`, `--check`, `--all`, `--json`, `--surface-scan`, `--verify`) executes synchronously in the caller's process and exits with a deterministic severity exit code (`0 = HEALTHY`, `1 = WARNING`, `2 = CRITICAL`).
  - Invoking without headless flags (or with `--menubar`) ensures execution inside the `.app` bundle, detaches from any controlling terminal via `posix_spawn` with `POSIX_SPAWN_SETSID`, acquires the non-blocking exclusive `flock(2)` on `menubar.lock`, and starts the `NSApplication` run loop.

### Section 5: Building Block View (C4 Level 3 — Component & Layer Architecture)
```mermaid
flowchart TD
    subgraph Presentation["Layer 4: Entrypoint & Presentation (src/main.swift, src/ui/)"]
        CLI["main.swift<br/>CLI Router & Session Detacher"]
        AppDel["AppDelegate.swift<br/>NSStatusItem, Sleep/Wake & Mount Observers"]
        Dash["DashboardMenuView.swift<br/>Popover Telemetry Card & Fleet Pill Switcher"]
        SetWin["SettingsWindowController & SettingsViewModel<br/>Ephemeral NSWindow & 6 Modular Tabs"]
    end

    subgraph Engine["Layer 3: Core Domain & Health Engine (src/engine/, src/diagnostics/, src/notifications/)"]
        Mon["DiskHealthMonitor.swift<br/>Multi-Disk Orchestrator, Baselines & Alert Cooldowns"]
        Rules["HealthRules.swift<br/>12 Pure Functional Sendable Rules"]
        Canary["CanaryProbeService.swift<br/>512B Sector-Aligned F_NOCACHE In-Place Probe"]
        Scanner["SurfaceScannerService.swift<br/>Multi-Tier F_NOCACHE Physical Media Reader"]
        Verifier["VolumeVerifierService.swift<br/>diskutil verifyVolume Runner & Output Classifier"]
        Diag["DiagnosticExporter.swift<br/>Sanitized JSON & Standalone HTML RMA Exporter"]
        Notifiers["MacOSNotifier / TelegramNotifier / WebhookNotifier"]
    end

    subgraph Infra["Layer 2: Configuration, Security & Models (src/config/, src/security/, src/models/)"]
        Cfg["ConfigManager.swift<br/>5-Tier Config Precedence & 5MB Rotating Logger"]
        Sec["SecretStore.swift & AtomicFileWriter<br/>Opt-In Keychain State Machine & 0600 POSIX Rename"]
        Lock["SingleInstanceLock.swift<br/>O_NOFOLLOW | O_CLOEXEC Non-Blocking flock"]
        Models["HealthModels.swift & DiskHealthError.swift<br/>Snapshots, Fleet Aggregations & Synchronized Formatters"]
    end

    subgraph Bridge["Layer 1: C11 / IOKit Hardware Bridge (src/bridge/)"]
        CBridge["DiskHealthBridge.c / .h<br/>IORegistry Traversal, APFS Pruning, 128-bit NVMe SMART, Static Cache"]
    end

    CLI --> Mon & Diag & Cfg & Lock
    AppDel --> Mon & Dash & SetWin & Diag
    SetWin --> Mon & Cfg & Sec
    Mon --> Rules & Canary & Scanner & Verifier & Notifiers & Cfg & Models
    Mon --> CBridge
    Diag --> Mon & Cfg & CBridge
    Cfg --> Sec & Models
```

#### Component Responsibilities Table
| Module / File | Primary Responsibility | Key Collaborators |
| :--- | :--- | :--- |
| `src/bridge/DiskHealthBridge.c` | Queries `IOBlockStorageDevice`, `IONVMeSMARTUserClient`, and `IOBlockStorageDriver`. Resolves APFS physical stores, prunes virtual APFS subtrees, and caches static properties per `IORegistryEntryID`. | `IOKit`, `CoreFoundation`, `sys/mount.h` |
| `src/engine/TelemetryProvider.swift` | Defines `DiskTelemetryProvider` protocol, live `IOKitTelemetryProvider` (bridging C11 + `statfs` + APFS purgeable space), and `MockTelemetryProvider` for deterministic fault injection. | `DiskHealthBridge.h`, `CanaryProbeService` |
| `src/engine/DiskHealthMonitor.swift` | Central singleton coordinating single-disk and fleet-wide (`evaluateAllMonitoredDisks`) evaluations, throughput delta calculation, baseline persistence, alert cooldowns, and daily digests. | `DiskTelemetryProvider`, `StandardHealthRulePipeline`, `ConfigManager`, Notifiers |
| `src/engine/HealthRules.swift` | Implements the 12 pure, side-effect-free `HealthRule` structs that map `HealthEvaluationContext` to `HealthRuleOutcome` (`issues`, `scorePenalty`, `logMessages`). | `HealthModels`, `VolumeVerifierService` |
| `src/engine/CanaryProbeService.swift` | Executes 512-byte sector-aligned in-place `pwrite`/`fsync`/`pread` probes with `F_NOCACHE` and a 300-second per-mount cache. | `Darwin.POSIX` |
| `src/engine/VolumeVerifierService.swift` | Spawns `/usr/sbin/diskutil verifyVolume` with a 180s watchdog, `pkill -P` child cleanup, and classification of `-69863` (permissions) vs `-69845` (corruption). | `Foundation.Process`, `Darwin` |
| `src/engine/SurfaceScannerService.swift` | Streams allocated files using 4KB-aligned buffers and `fcntl(fd, F_NOCACHE, 1)` across `quick` (64 MB), `standard` (2 GB), and `full` volume modes. | `FileManager`, `Darwin.POSIX` |
| `src/config/ConfigManager.swift` | Resolves 5-tier configuration precedence (`CLI > Env > .env > config.json > Defaults`), redacts secrets, and manages the 5 MB rotating `health.log`. | `SecretStore`, `AtomicFileWriter` |
| `src/security/SecretStore.swift` | Manages the opt-in Keychain state machine (`KeychainIntegrationState`), session cache, and `AtomicFileWriter` (`0600` POSIX write + `fsync` + `rename`). | `Security.framework`, `Darwin.POSIX` |

### Section 6: Runtime View (Key Operational Sequences)

#### 6.1 Multi-Disk Fleet Polling & Rule Evaluation Sequence
```mermaid
sequenceDiagram
    autonumber
    participant Timer as AppDelegate / CLI
    participant Mon as DiskHealthMonitor
    participant Prov as IOKitTelemetryProvider
    participant Bridge as DiskHealthBridge.c
    participant Canary as CanaryProbeService
    participant Rules as StandardHealthRulePipeline
    participant Disk as AtomicFileWriter (0600)

    Timer->>Mon: evaluateAllMonitoredDisks(forceCanary, allowNotifications)
    activate Mon
    Note over Mon: Acquire engineLock
    Mon->>Prov: listAllDevices(maxCount: 32) (if monitorAllDisks)
    Prov->>Bridge: DiskListAllDevices(&raw, 32)
    Bridge-->>Prov: Physical DiskHardwareMetrics[] (Static cache + live SMART/Driver stats)
    loop For each deduplicated target disk
        Mon->>Prov: findMountPoint(forBsdName:)
        Prov->>Bridge: DiskFindMountForBlockDevice() (stackFs[64] + score pruning)
        Bridge-->>Prov: Resolved mount path (e.g. "/" or "/Volumes/T7")
        Mon->>Prov: inspectFilesystem(mountPath) (statfs + APFS purgeable space)
        alt Volume Mounted & Canary Enabled & !isSystemSleeping
            Mon->>Canary: runCanaryCheck(targetMount, force, nowTs)
            Canary-->>Mon: CanaryProbeResult (cached 300s or live 512B pwrite+fsync+pread)
        end
        Mon->>Rules: evaluate(context: HealthEvaluationContext) across 12 Pure Rules
        Rules-->>Mon: HealthRuleOutcome (issues, scorePenalty, logMessages)
        Mon->>Mon: Update DriveBaselineState & evaluate scoped alert cooldowns
    end
    Mon->>Mon: Aggregate MultiDiskHealthSnapshot (worstSeverity, worstScore, avgScore)
    Mon->>Disk: Write latest_status.json & state.json (only if dirty) with mode 0600
    Note over Mon: Release engineLock & dispatch @Published updates to Main Thread
    deactivate Mon
```

#### 6.2 Active Canary Probe & Fallback Decision Flow
```mermaid
flowchart TD
    Start(["runCanaryCheck(targetMount, force, nowTs)"]) --> CacheCheck{"!force && cached < 300s?"}
    CacheCheck -- Yes --> ReturnCached(["Return Cached CanaryProbeResult"])
    CacheCheck -- No --> RootCheck{"targetMount == '/'?"}
    RootCheck -- Yes --> DataTmp["Use /System/Volumes/Data/private/tmp"]
    RootCheck -- No --> DirectMount["Use targetMount"]
    DataTmp & DirectMount --> OpenFile["open(.disk_health_canary_<uid>, O_CREAT|O_RDWR|O_NOFOLLOW|O_CLOEXEC, 0600)"]
    OpenFile --> OpenOk{"fd >= 0?"}
    OpenOk -- "No (EACCES/EPERM)" --> SelfHeal["Self-Heal: unlink() orphaned 0400 file & retry open()"]
    SelfHeal --> OpenOk2{"fd >= 0?"}
    OpenOk -- "No (EROFS)" --> ReadFallback["Fallback: opendir() + readdir() active directory probe"]
    OpenOk2 -- "No (EPERM/EACCES/EROFS)" --> ReadFallback
    OpenOk2 -- "No (Other errno)" --> FailOpen(["Return ok: false, open write failed"])
    OpenOk -- Yes --> SetNoCache["fcntl(fd, F_NOCACHE, 1)<br/>Pad payload to 512-byte sector boundary"]
    OpenOk2 -- Yes --> SetNoCache
    SetNoCache --> PWrite["pwrite(fd, buf, 512, offset 0)"]
    PWrite --> EinvalCheck{"written < 0 && errno == EINVAL?"}
    EinvalCheck -- "Yes (FAT32/exFAT driver)" --> DisableNoCache["fcntl(fd, F_NOCACHE, 0) & retry pwrite()"]
    EinvalCheck -- No --> CheckWrite{"written == 512?"}
    DisableNoCache --> CheckWrite
    CheckWrite -- No --> FailWrite(["close(fd), unlink(), Return write failed"])
    CheckWrite -- Yes --> Fsync["fsync(fd)"]
    Fsync --> CheckFsync{"fsync == 0?"}
    CheckFsync -- No --> FailFsync(["close(fd), unlink(), Return fsync failed"])
    CheckFsync -- Yes --> PRead["pread(fd, readBuf, 512, offset 0) & close(fd)"]
    PRead --> Verify{"readBuf == buf?"}
    Verify -- No --> FailVerify(["unlink(), Return readback mismatch"])
    Verify -- Yes --> CheckSpike{"!ok || latencyMs > 300ms?"}
    ReadFallback --> CheckSpike
    CheckSpike -- "Yes (First Pass)" --> RetryPass["usleep(50ms) & run 2nd confirmation pass"]
    CheckSpike -- No --> StoreCache["Store in cacheByMount[key] & Return Result"]
    RetryPass --> StoreCache
```

### Section 7: Deployment & Packaging View
- **Artifacts Generated by `build_and_install.sh`**:
  - `DiskHealthMonitor.app`: Ad-hoc codesigned (`codesign --force --deep --sign -`), quarantine-stripped, `LSUIElement = true` bundle synced automatically to `/Applications` or `~/Applications` if present.
  - `./disk-health`: Relative CLI symlink pointing to `DiskHealthMonitor.app/Contents/MacOS/DiskHealthMonitor`.
  - `~/Library/LaunchAgents/io.github.disk-health-monitor.plist`: Background LaunchAgent configured with `KeepAlive = { SuccessfulExit = false }` and `ProcessType = Interactive`.
  - Release `--package` artifacts (`dist/`): `arm64`, `x86_64`, and `universal` DMGs, ZIPs, standalone CLI binaries, and `SHA256SUMS.txt`.

### Section 8: Cross-Cutting Concepts

#### 8.1 Concurrency, Thread Safety & Lock Hierarchy
To prevent deadlocks and main-thread priority inversions without requiring Swift 6 macro plugins, the system enforces a strict **acyclic lock hierarchy**:

```mermaid
flowchart LR
    UI["Main Thread (@MainActor / AppKit)<br/>Reads publishedSnapshot & publishedMultiSnapshot Lock-Free"]
    Debounce["SettingsViewModel.debounceLock<br/>(NSLock)"]
    Engine["DiskHealthMonitor.engineLock<br/>(NSRecursiveLock)"]
    CfgLock["ConfigManager.configLock<br/>(NSRecursiveLock)"]
    SecLock["SecretStore.lock<br/>(NSRecursiveLock)"]
    LogLock["ConfigManager.logLock<br/>(NSLock)"]
    CanaryLock["CanaryProbeService.lock<br/>(NSLock)"]
    StaticMutex["DiskHealthBridge.sStaticCacheMutex<br/>(pthread_mutex_t)"]

    UI -.->|"Async dispatch (.userInitiated)"| Engine
    Debounce --> SecLock & CfgLock
    Engine --> CfgLock
    Engine --> CanaryLock
    Engine --> LogLock
    Engine --> StaticMutex
    CfgLock --> SecLock
```

**Invariants**:
1. `ConfigManager.configLock` **NEVER** calls into `DiskHealthMonitor` (preventing AB-BA deadlocks with `engineLock`).
2. `ConfigManager` always releases `configLock` **before** invoking `notifyObjectWillChangeOnMain()`.
3. `DiskHealthMonitor.selectDashboardDrive(key:)` updates main-thread `@Published` properties immediately and acquires `engineLock` asynchronously on a `.userInitiated` background queue (`SYS2-02`).

#### 8.2 Memory Ownership Across C11 / CoreFoundation / IOKit
Every kernel/CF resource in `DiskHealthBridge.c` obeys deterministic pairing:
- `IOServiceGetMatchingServices` / `IORegistryEntryGetChildIterator` / `IORegistryEntryGetParentIterator` $\rightarrow$ `IOObjectRelease(iter)`
- `IOIteratorNext` / `IOServiceGetMatchingService` / `IORegistryEntryGetParentEntry` $\rightarrow$ `IOObjectRelease(entry)`
- `IORegistryEntryCreateCFProperty` $\rightarrow$ `CFRelease(propRef)`
- `IOCreatePlugInInterfaceForService` $\rightarrow$ `IODestroyPlugInInterface(plugin)`
- `(*plugin)->QueryInterface(..., &smart)` $\rightarrow$ `(*smart)->Release(smart)`

### Section 9: Architecture Decisions (ADRs)
Include 7 concise, formal ADRs in `docs/ARCHITECTURE.md`:
- **ADR-001**: Single-Binary Dual-Mode Architecture (`POSIX_SPAWN_SETSID` terminal detachment + `SingleInstanceLock`).
- **ADR-002**: C11 Hardware Bridge over Swift IOKit Bindings (COM-style `IOCFPlugInInterface` vtables and 128-bit NVMe struct alignment).
- **ADR-003**: Pure Functional 12-Rule Health Evaluation Pipeline (`HealthEvaluationContext` $\rightarrow$ `HealthRuleOutcome` with `MockTelemetryProvider` injection).
- **ADR-004**: Opt-In Keychain State Machine with `0600` Local Fallback (preventing headless/daemon `securityd` modal lockups).
- **ADR-005**: Sector-Aligned (`512B`) In-Place Canary Probe with `F_NOCACHE` (eliminating APFS B-tree directory churn and supporting FAT32/exFAT).
- **ADR-006**: Static IOKit Registry Memoization Keyed by `IORegistryEntryID` with Live `IOMedia` BSD Inspection.
- **ADR-007**: Ephemeral Settings Window Lifecycle (`windowWillClose` teardown saving 15–22 MB idle daemon RSS).

### Section 10: Quality Requirements & Verification Matrix
Map the 5-stage test suite (`15` C tests, `40` Swift tests, `14` CLI integration checks, Exporters/Scanners, Bundle verification) to the architectural components they certify.

### Section 11: Technical Risks, Pitfalls & Mitigations (Lead Architect Self-Assessment)
*(See Part 3 below for the complete adversarial assessment to include in Section 11 of `docs/ARCHITECTURE.md`.)*

### Section 12: Glossary
Define domain terms: `APFS Physical Store`, `BSD Name`, `Data Unit (NVMe)`, `Dark Wake`, `F_NOCACHE`, `IONVMeSMARTUserClient`, `Percentage Used`, `POH`, `TBW`.

---

# Part 3: Lead Architect Assessment — Potential Pitfalls, Improvements & Optimizations

As requested by the user:
> *"After doing so, the document should be assessed by argon that will respond with potential pitfalls, improvements and optimizations"*

Even with `v2.4.0 Build 7` passing all 55 unit tests and 5 integration stages, a Lead Systems Architect must evaluate **long-horizon operational pitfalls, architectural trade-offs, and future optimization vectors** under extreme macOS workloads. These must be documented in **Section 11 of `docs/ARCHITECTURE.md`** and serve as the engineering roadmap for future releases:

### 1. Pitfall: Synchronous Polling Contention on High-Drive-Count Topologies (JBOD / Thunderbolt RAID)
- **Mechanism**: In `DiskHealthMonitor.evaluateAllMonitoredDisks`, the engine acquires `engineLock` once and iterates sequentially over all discovered drives (`for dev in enumeratedDevices`). On a Mac Studio or Mac Pro with 8–12 external USB/Thunderbolt drives, if one external HDD/SSD is in link-power-state sleep (spinning up or waking controller), its `statfs` or `CanaryProbeService` `fsync(fd)` can take `1.5s–3.0s`.
- **Impact**: While `selectDashboardDrive(key:)` and `DashboardMenuView` read `@Published` properties without locking on the main thread, any CLI command or background caller accessing `monitor.currentMultiSnapshot` will block until the entire sequential loop finishes.
- **Architectural Optimization (Future v2.5)**:
  - **Snapshot Copy-on-Write (CoW) / Lock Splitting**: Separate `engineLock` into a lightweight `snapshotReadLock` (held for nanoseconds only when swapping `latestMultiSnapshotInternal`) and a `pollExecutionLock` (serializing evaluation cycles).
  - **Bounded Concurrent Per-Disk Probing**: Use `DispatchQueue.concurrentPerform` (or a Swift `TaskGroup` with max concurrency 4) to run `CanaryProbeService` and `statfs` across independent physical disks in parallel before aggregating results under the state lock.

### 2. Pitfall: USB-to-NVMe Bridge SAT/SCSI Pass-Through Blindness
- **Mechanism**: `DiskHealthBridge.c` queries NVMe S.M.A.R.T. via `kIONVMeSMARTUserClientTypeID`. Internal Apple Silicon/Intel SSDs and Thunderbolt PCIe NVMe enclosures expose native `IONVMeController` nodes. However, many USB 3.2 Gen 2 enclosures (e.g., Realtek `RTL9210`, ASMedia `ASM2362`, JMicron `JMS583`) present the NVMe drive to macOS over **USB Attached SCSI (UASP / `IOBlockStorageServices`)** rather than native PCIe NVMe. Consequently, `IOCreatePlugInInterfaceForService(..., kIONVMeSMARTUserClientTypeID, ...)` returns `kIOReturnUnsupported`, setting `smartValid = false`.
- **Impact**: For USB UASP enclosures, the monitor falls back to `IOBlockStorageDriver` kernel error/latency counters, link speed checks, capacity checks, and active canary probes, but cannot read temperature or wear percentage without SAT/NVMe SCSI pass-through.
- **Architectural Improvement (Future v2.5)**:
  - Add an optional secondary probe in `DiskHealthBridge.c` for `IOSCSIPeripheralDeviceType00` / `SCSITaskUserClient` issuing a non-destructive SCSI Log Sense / SAT ATA PASS-THROUGH or NVMe Admin Pass-Through CDB (`0x85` / `0xA2`) when `kIONVMeSMARTUserClientTypeID` is unavailable on external USB bridges.

### 3. Pitfall: `sStaticCache` Ring-Buffer Thrashing on >32 Virtual Disk Images
- **Mechanism**: `DiskHealthBridge.c` defines `#define MAX_STATIC_CACHE_ENTRIES 32`. If a developer or CI server mounts more than 32 `.dmg` disk images or Xcode simulator runtime volumes (`disk4` through `disk45`), `DiskListAllDevices` will cycle through >32 `IOBlockStorageDevice` entries in a single pass, causing the 32-slot FIFO ring buffer `sStaticCache` to evict entries on every poll cycle.
- **Impact**: No functional bug (since evicted entries simply re-query `IORegistryEntryCreateCFProperty`), but loses the CPU memoization benefit when >32 virtual block devices are attached.
- **Architectural Optimization**:
  - Skip inserting virtual disk images (`IOHDIXHDDriveOutKernel` / `AppleDiskImageDevice` / `Virtual Interface`) into `sStaticCache`, or increase `MAX_STATIC_CACHE_ENTRIES` to `64`.

### 4. Pitfall: LaunchAgent `KeepAlive` Interaction with Manual "Quit Disk Health Monitor" (`⌘Q`)
- **Mechanism**: `build_and_install.sh` and `SettingsViewModel.makeLaunchAgentPlistDict` configure `KeepAlive = ["SuccessfulExit": false]`. When a user clicks `Quit Disk Health Monitor (⌘Q)`, `NSApplication.shared.terminate(nil)` exits with status `0` (`SuccessfulExit == true`), so `launchd` properly leaves the app stopped until next login. However, if a signal (`SIGTERM`) terminates the process with a non-zero wait status, `launchd` respawns it.
- **Improvement**: This subtle contract is a classic macOS LaunchAgent pitfall and is now explicitly documented in `SettingsViewModel.swift` and `docs/ARCHITECTURE.md`.

---

# Part 4: Step-by-Step Execution Plan for Gemini 3.8 Flash (High)

> **INSTRUCTIONS FOR GEMINI 3.8 FLASH (HIGH)**:
> Execute the following 3 phases to:
> 1. Author the comprehensive `docs/ARCHITECTURE.md` following the arc42 + C4 Mermaid blueprint and including the Section 11 Lead Architect Pitfalls & Optimizations review.
> 2. Add standardized file header banners, Doxygen/HeaderDoc comments, `///` Swift DocC comments, concurrency/lock precondition annotations, and `// MARK: -` section dividers across the C11 and Swift source files to make the codebase human-readable and coherent.
> 3. Run the full build and 5-stage test suite (`./build_and_install.sh && ./tests/run_tests.sh`) to verify zero warnings and 100% test pass rate.

### Phase 1: Create Master Architectural Documentation (`docs/ARCHITECTURE.md`) & Update `README.md`
1. Create `docs/ARCHITECTURE.md` containing all 12 arc42 sections, C4 Mermaid diagrams (System Context, Container, Component, Runtime Sequences, Lock Hierarchy), the 7 ADRs, and Section 11 (Argon Lead Architect Assessment of Pitfalls, Improvements & Optimizations).
2. Add a prominent link to [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) in the root `README.md` under **System Architecture**.

### Phase 2: Codebase Coherence, HeaderDoc & Inline Invariant Documentation (`src/`)
Apply standardized file headers, docblocks, and invariant explanations across:
1. **C11 Bridge (`src/bridge/DiskHealthBridge.h`, `src/bridge/DiskHealthBridge.c`)**:
   - Add Doxygen `@brief`, `@param`, `@return`, and `@note` comments to all public functions in `DiskHealthBridge.h` and static helpers in `DiskHealthBridge.c`.
   - Document the `sStaticCache` `bsdName` omission invariant (`UAT2-03`), APFS subtree pruning (`C11-01`), USB/Thunderbolt parent precedence (`SYS-06`), and `stackFs[64]` fast path (`OPT2-02`).
2. **Core Engine (`src/engine/*.swift`)**:
   - Document `DiskHealthMonitor` lock discipline (`engineLock`), `selectDashboardDrive(key:)` main-thread priority-inversion avoidance (`SYS2-02`), dirty-state persistence (`OPT-06`), and dynamic hot-unplug handling (`SYS-07`).
   - Document `CanaryProbeService` 512-byte sector alignment (`UAT2-01`), `0400` orphan self-healing (`UAT2-04`), and per-mount caching (`OPT-04`).
   - Document `VolumeVerifierService` child process group termination (`SYS2-05`) and `-69863` privilege classification.
   - Document `HealthRules.swift` pure functional evaluation contract and `TelemetryProvider.swift` APFS purgeable capacity accounting.
3. **Config, Security, Models, Diagnostics, Notifications & UI (`src/config/`, `src/security/`, `src/models/`, `src/diagnostics/`, `src/notifications/`, `src/ui/`, `src/main.swift`)**:
   - Add file header banners and docblocks explaining `AtomicFileWriter` `0600` zero-window creation, `SecretStore` opt-in Keychain state machine, `SingleInstanceLock` `O_NOFOLLOW` protection, `DiagnosticExporter` reverse-seek UTF-8 boundary handling (`SYS2-01`), `SettingsWindowController` ephemeral memory lifecycle (`OPT2-03`), and `main.swift` `POSIX_SPAWN_SETSID` terminal detachment.

### Phase 3: Build & Full Regression Verification
Run:
```bash
./build_and_install.sh && ./tests/run_tests.sh
```
Confirm zero compiler warnings in `clang` and `swiftc`, 15/15 C bridge tests passing, 40/40 Swift unit tests passing, and all CLI integration checks passing.
