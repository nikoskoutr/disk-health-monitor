# Universal Disk Health Monitor: System Architecture Specification

**Standard:** arc42 Architecture Template (v8.2) & C4 Model-as-Code (Mermaid)  
**System:** Universal macOS Disk Health Monitor & Telemetry Agent  
**Version:** `v2.6.0` (Build 9)  
**Target Architectures:** Universal Binary (`arm64` Apple Silicon & `x86_64` Intel)  
**Target Platform:** macOS 13.0 (Ventura) through macOS 15+ (Sequoia)  

---

## Table of Contents
1. [Introduction and Goals](#1-introduction-and-goals)
2. [Architecture Constraints](#2-architecture-constraints)
3. [System Scope and Context (C4 Level 1)](#3-system-scope-and-context-c4-level-1)
4. [Solution Strategy & Container View (C4 Level 2)](#4-solution-strategy--container-view-c4-level-2)
5. [Building Block View (C4 Level 3)](#5-building-block-view-c4-level-3)
6. [Runtime View (Operational Sequences & State Machines)](#6-runtime-view-operational-sequences--state-machines)
7. [Deployment & Packaging View](#7-deployment--packaging-view)
8. [Cross-Cutting Concepts](#8-cross-cutting-concepts)
9. [Architecture Decision Records (ADRs)](#9-architecture-decision-records-adrs)
10. [Quality Requirements & Verification Matrix](#10-quality-requirements--verification-matrix)
11. [Technical Risks, Pitfalls & Optimization Roadmap](#11-technical-risks-pitfalls--optimization-roadmap)
12. [Glossary & References](#12-glossary--references)

---

## 1. Introduction and Goals

### 1.1 System Purpose & Executive Summary
The **Universal Disk Health Monitor** is an autonomous, lightweight, zero-dependency storage telemetry daemon, interactive Menu Bar monitor, and CLI diagnostics utility engineered exclusively for macOS. It monitors both internal Apple Silicon/Intel NVMe solid-state storage and external drives (USB 3.x/4, Thunderbolt, and SATA enclosures). 

The system operates across two complementary operational modalities through a single universal Mach-O binary:
1. **Interactive AppKit/SwiftUI Menu Bar Application (`LSUIElement`)**: Resides unobtrusively in the macOS menu bar, rendering real-time health badges, storage gauges, live throughput graphs, S.M.A.R.T. hardware attributes, and an ephemeral multi-tab Settings controller.
2. **Headless CLI & LaunchAgent Background Daemon**: Dispatches periodic health evaluations, sends multi-channel alerts (macOS Notification Center, Telegram Bot API, Webhooks, custom shell scripts), generates sanitized JSON/HTML diagnostics, and automates non-destructive media surface scanning.

### 1.2 Quality Goals (ISO/IEC 25010)

| Priority | Quality Attribute | Architectural Objective & SLA Metric |
| :---: | :--- | :--- |
| **1** | **Reliability & Safety** | Zero kernel panics, zero unhandled exceptions, zero data destruction. Active canary probes are strictly non-destructive, using 512-byte sector-aligned in-place I/O with read-back verification. |
| **2** | **Resource Efficiency** | `< 0.1%` average CPU overhead during 30s background polling; `< 25 MB` Resident Set Size (RSS) in daemon mode via static IOKit registry memoization (`sStaticCache`) and ephemeral Settings window teardown. |
| **3** | **Security & Privacy** | Zero unprompted Keychain modal popups in headless/daemon mode (`allowInteractiveKeychain == false`). Atomic `0600` POSIX file writes with `O_NOFOLLOW` symlink protection. Automated redaction of sensitive credentials in exports and logs. |
| **4** | **Observability** | Deterministic severity exits (`0 = HEALTHY`, `1 = WARNING`, `2 = CRITICAL`). Dual-format diagnostic exports (machine-readable JSON + standalone styled HTML with embedded SVG visualizations). |
| **5** | **Maintainability** | Zero third-party dependencies. Pure functional domain rules (`HealthRule` protocol) decoupled from I/O side effects, enabling 100% deterministic unit testing without hardware access. |

### 1.3 Stakeholders & Personas

```mermaid
mindmap
  root((Stakeholders))
    DevOps & SysAdmins
      Unattended launchd daemons
      Automated Telegram/Webhook alerting
      JSON status pipelines for monitoring
      Deterministic exit codes for shell scripts
    Mac Power Users
      At-a-glance Menu Bar health badges
      Live throughput and wear monitoring
      External drive hot-plug auto-discovery
      Non-destructive surface scans
    Hardware Technicians & RMA
      Standalone HTML RMA reports
      Raw NVMe 128-bit counter audits
      Filesystem verification history
      Hardware interconnect link speed validation
```

---

## 2. Architecture Constraints

### 2.1 Technical Constraints
- **Zero Third-Party Dependencies**: The entire project is compiled strictly against Apple system frameworks (`IOKit`, `CoreFoundation`, `Security`, `UserNotifications`, `AppKit`, `SwiftUI`) and Darwin/POSIX libc headers (`sys/mount.h`, `sys/param.h`, `pthread.h`, `fcntl.h`). No external package managers (SwiftPM, CocoaPods, Carthage) or dynamic dylibs are permitted.
- **Direct Compiler Toolchain**: Built directly via `build_and_install.sh` invoking `clang` and `swiftc` with `-O -whole-module-optimization -Xlinker -dead_strip`. Prohibits compiler macro plugins (e.g., Swift 5.9 `@Observable`) that require external host tools.
- **Single-Binary Dual-Mode Execution**: The executable at `DiskHealthMonitor.app/Contents/MacOS/DiskHealthMonitor` and the symlink `./disk-health` represent the exact same Mach-O universal binary. Argument routing dynamically switches between headless CLI execution and AppKit menu bar initialization.
- **Platform Support**: Native compilation for `arm64` (Apple Silicon M1/M2/M3/M4) and `x86_64` (Intel). Operating system targets: macOS 13.0 (Ventura), macOS 14 (Sonoma), and macOS 15 (Sequoia).

### 2.2 Security & Kernel Constraints
- **Unprivileged Execution**: The application runs under standard non-root user credentials. Volume verification via `/usr/sbin/diskutil verifyVolume` gracefully handles unprivileged return code `-69863` as informational rather than a fatal failure.
- **Sandboxing & Permission Isolation**: Config and log directories are enforced at `0700` (`S_IRWXU`), and persistent files (`config.json`, `state.json`, `latest_status.json`) are created with `0600` (`S_IRUSR | S_IWUSR`) permissions using atomic rename semantics.

---

## 3. System Scope and Context (C4 Level 1)

The Universal Disk Health Monitor sits at the boundary between user space, macOS kernel storage drivers, and external notification endpoints.

```mermaid
flowchart TB
    User["👤 macOS User / Systems Admin<br/>(Interactive CLI & Menu Bar UI)"]
    Launchd["⚙️ macOS launchd<br/>(Background Agent & Mount Trigger)"]
    
    subgraph SystemBoundary["🛡️ Universal Disk Health Monitor System"]
        DHM["Universal Disk Health Monitor<br/>(Single Universal Mach-O Binary)"]
    end
    
    Kernel["🍎 Darwin Kernel & IOKit Subsystems<br/>(IONVMeSMARTUserClient, IOBlockStorageDriver, VFS statfs)"]
    DiskUtil["🔧 /usr/sbin/diskutil<br/>(Child Process: verifyVolume / fsck_apfs)"]
    Keychain["🔐 macOS Security.framework<br/>(System Keychain & Local Secret Fallback)"]
    Alerts["🔔 Alert Endpoints<br/>(macOS Notification Center, Telegram Bot API, Webhooks, Shell Hooks)"]

    User -->|"CLI flags (--status, --all, --json) / Menu Bar (⌘, ⌘I, ⌘S)"| DHM
    Launchd -->|"Spawns & supervises via launchd.plist (--menubar)"| DHM
    DHM -->|"Mach ports, IORegistry traversal, direct POSIX I/O"| Kernel
    DHM -->|"Spawns with 180s timeout watchdog & pkill -P"| DiskUtil
    DHM -->|"Opt-in SecItemCopyMatching / 0600 file"| Keychain
    DHM -->|"HTTPS POST / UNNotificationRequest / posix_spawn"| Alerts
```

### 3.1 External System Interfaces
- **Darwin Kernel & IOKit**:
  - `IOServiceGetMatchingServices`: Traverses physical block devices (`IOBlockStorageDevice`).
  - `IOCreatePlugInInterfaceForService`: Instantiates `IONVMeSMARTUserClient` COM-style vtable to read low-level NVMe SMART structures.
  - `statfs(2)` & `getattrlist(2)`: Gathers filesystem capacity, mount flags, and APFS purgeable byte allocations.
  - `fcntl(fd, F_NOCACHE, 1)`: Bypasses macOS Unified Buffer Cache (UBC) for authentic direct media reads/writes.
- **macOS launchd**: Manages the life cycle of the background menu bar agent (`io.github.disk-health-monitor.plist`), handling auto-start at login and mount-triggered one-shot evaluations.
- **macOS Security.framework**: Provides persistent credential storage for Telegram Bot Tokens and Webhook URLs via `kSecClassGenericPassword` with zero modal dialogs during headless operation.
- **Alert Endpoints**:
  - `UserNotifications.framework`: Native desktop notification banners and alerts.
  - `URLSession`: Asynchronous HTTPS POST payloads to Telegram Bot API and generic Webhook endpoints.
  - `posix_spawn`: User-defined external notification shell scripts with 15-second watchdog isolation.

---

## 4. Solution Strategy & Container View (C4 Level 2)

The system is organized into modular functional containers bundled within a single universal binary.

```mermaid
flowchart TD
    subgraph Binary["Mach-O Binary: DiskHealthMonitor (arm64 + x86_64)"]
        direction TB

        subgraph ContainerCLI["CLI & Process Controller"]
            Entry["main.swift<br/>Argument Parser & POSIX_SPAWN_SETSID Detacher"]
            SingleLock["SingleInstanceLock.swift<br/>Non-blocking flock with O_NOFOLLOW"]
        end

        subgraph ContainerUI["Presentation Container (AppKit & SwiftUI)"]
            AppDelegate["AppDelegate.swift<br/>NSStatusItem & Sleep/Mount Listeners"]
            DashMenu["DashboardMenuView.swift<br/>Popover Telemetry Card & Fleet Selector"]
            SettingsCtrl["SettingsWindowController & ViewModel<br/>Ephemeral NSWindow & 6 Config Tabs"]
        end

        subgraph ContainerEngine["Telemetry & Domain Engine"]
            EngineCoord["DiskHealthMonitor.swift<br/>Multi-Disk Coordinator, Baselines & Cooldowns"]
            RulePipeline["HealthRules.swift<br/>12 Pure Functional Sendable Rules"]
            ProbeSvc["CanaryProbeService.swift<br/>512B Sector-Aligned F_NOCACHE Probe"]
            VerifySvc["VolumeVerifierService.swift<br/>diskutil Runner & Process Tree Killer"]
            ScanSvc["SurfaceScannerService.swift<br/>Direct I/O Sector Reader with ETA"]
        end

        subgraph ContainerInfra["Security, Config & Diagnostics"]
            CfgMgr["ConfigManager.swift<br/>5-Tier Precedence & Rotating 5MB Logger"]
            SecStore["SecretStore.swift & AtomicFileWriter<br/>Opt-in Keychain State Machine & 0600 Writer"]
            DiagExp["DiagnosticExporter.swift<br/>Sanitized JSON & Standalone HTML RMA Generator"]
            NotifAdapters["Notifiers<br/>macOS UserNotifications, Telegram, Webhook"]
        end

        subgraph ContainerBridge["Hardware Abstraction Layer (C11)"]
            BridgeC["DiskHealthBridge.c / .h<br/>IORegistry Traversal, APFS Pruner, 128-bit NVMe Reader, Static Cache"]
        end
    end

    Entry --> SingleLock & EngineCoord & DiagExp & CfgMgr
    Entry -->|"Spawn UI run loop"| AppDelegate
    AppDelegate --> DashMenu & SettingsCtrl & EngineCoord
    SettingsCtrl --> CfgMgr & SecStore & EngineCoord
    EngineCoord --> RulePipeline & ProbeSvc & VerifySvc & ScanSvc & NotifAdapters & CfgMgr
    EngineCoord --> ContainerBridge
    DiagExp --> EngineCoord & ContainerBridge & CfgMgr
    CfgMgr --> SecStore
```

### 4.1 Process Bootstrap Logic
1. `main.swift` receives `CommandLine.arguments`.
2. If flags represent an interactive or headless command (`--status`, `--all`, `--json`, `--check`, `--surface-scan`, etc.):
   - Evaluates telemetry synchronously on the calling thread.
   - Outputs formatted results to `stdout` / `stderr`.
   - Exits immediately with severity status (`0`, `1`, or `2`).
3. If no flags are provided or `--menubar` is passed:
   - Validates whether the binary is running from within an active application bundle (`DiskHealthMonitor.app`). If invoked from terminal directly, it invokes `posix_spawn` with `POSIX_SPAWN_SETSID` to detach from the controlling TTY.
   - Acquires the non-blocking `flock(2)` on `~/.config/disk-health-monitor/menubar.lock`.
   - Initializes `NSApplication.shared`, assigns `AppDelegate`, and enters `NSApplicationMain`.

---

## 5. Building Block View (C4 Level 3)

### 5.1 Component Hierarchy & Dependency Layers

```mermaid
flowchart TD
    subgraph Layer4["Layer 4: Presentation & CLI Router"]
        L4_CLI["src/main.swift"]
        L4_AppDel["src/ui/AppDelegate.swift"]
        L4_Dash["src/ui/DashboardMenuView.swift"]
        L4_SetVM["src/ui/SettingsViewModel.swift"]
        L4_Tabs["src/ui/tabs/*.swift (6 Tabs)"]
    end

    subgraph Layer3["Layer 3: Core Domain & Services Engine"]
        L3_Mon["src/engine/DiskHealthMonitor.swift"]
        L3_Rules["src/engine/HealthRules.swift"]
        L3_Canary["src/engine/CanaryProbeService.swift"]
        L3_Scan["src/engine/SurfaceScannerService.swift"]
        L3_Ver["src/engine/VolumeVerifierService.swift"]
        L3_TelProv["src/engine/TelemetryProvider.swift"]
        L3_Diag["src/diagnostics/DiagnosticExporter.swift"]
        L3_Notif["src/notifications/*.swift"]
    end

    subgraph Layer2["Layer 2: Infrastructure, Security & Persistence"]
        L2_Cfg["src/config/ConfigManager.swift"]
        L2_Sec["src/security/SecretStore.swift"]
        L2_Lock["src/security/SingleInstanceLock.swift"]
        L2_Mod["src/models/HealthModels.swift"]
        L2_Err["src/models/DiskHealthError.swift"]
    end

    subgraph Layer1["Layer 1: Low-Level Darwin C11 Hardware Bridge"]
        L1_Bridge["src/bridge/DiskHealthBridge.c"]
        L1_H["src/bridge/DiskHealthBridge.h"]
    end

    Layer4 --> Layer3 & Layer2
    Layer3 --> Layer2 & Layer1
    Layer2 --> Layer1
```

### 5.2 Component Responsibilities Matrix

| Component File | Subsystem | Core Responsibilities & Invariants |
| :--- | :--- | :--- |
| `src/bridge/DiskHealthBridge.c` | Hardware Bridge | Traverses `IOBlockStorageDevice` and `IONVMeSMARTUserClient`. Prunes virtual APFS child subtrees to prevent physical BSD name clobbering. Implements `sStaticCache` ring-buffer memoizing invariant hardware strings per `IORegistryEntryID`. |
| `src/engine/TelemetryProvider.swift` | Domain Engine | Defines `DiskTelemetryProvider` protocol. Implements `IOKitTelemetryProvider` combining C bridge hardware metrics with Darwin `statfs` and APFS purgeable space accounting. Implements `MockTelemetryProvider` for deterministic fault injection. |
| `src/engine/DiskHealthMonitor.swift` | Domain Engine | Central orchestrator managing single-disk and fleet-wide (`evaluateAllMonitoredDisks`) evaluations, baseline delta tracking, scoped alert cooldowns, dirty-state persistence, and `@MainActor` thread decoupling. |
| `src/engine/HealthRules.swift` | Domain Engine | 12 pure functional, side-effect-free `HealthRule` implementations mapping `HealthEvaluationContext` to `HealthRuleOutcome` (`issues`, `scorePenalty`, `logMessages`). |
| `src/engine/CanaryProbeService.swift` | Active Probing | Performs sector-aligned (512-byte) in-place `pwrite`/`fsync`/`pread` probes with `F_NOCACHE` and 300s mount caching. Implements `0400` orphan self-healing. |
| `src/engine/VolumeVerifierService.swift` | Filesystem Verification | Asynchronously spawns `/usr/sbin/diskutil verifyVolume` with a 180s watchdog, terminates child process trees (`pkill -P`), and classifies exit codes (`-69863` privilege vs `-69845` corruption). |
| `src/engine/SurfaceScannerService.swift` | Media Inspection | Reads allocated storage using 4KB sector buffers and `fcntl(fd, F_NOCACHE, 1)` across `quick` (64 MB), `standard` (2 GB), and `full` modes with ETA calculation and cancellation tokens. |
| `src/config/ConfigManager.swift` | Configuration | Resolves 5-tier configuration precedence (`CLI > Env > .env > config.json > Defaults`), handles JSON serialization, masks credentials, and manages the 5 MB rotating log. |
| `src/security/SecretStore.swift` | Security | Manages the opt-in Keychain state machine (`KeychainIntegrationState`) to guarantee zero unprompted modal dialogs during daemon operation. Implements `AtomicFileWriter` (`0600` POSIX write + `fsync` + `rename`). |
| `src/security/SingleInstanceLock.swift` | Concurrency | Enforces single-instance execution via non-blocking `flock(2)` on `menubar.lock` with `O_NOFOLLOW` symlink attack protection. |
| `src/diagnostics/DiagnosticExporter.swift` | Diagnostics | Compiles JSON diagnostic bundles and standalone HTML health reports with embedded SVGs and reverse-seek boundary-safe log tailing (`SYS2-01`). |
| `src/ui/AppDelegate.swift` | UI Presentation | Manages `NSStatusItem`, status bar title caching (truncated to $\le 18$ characters), workspace mount notifications, and sleep/wake power notifications. |
| `src/ui/DashboardMenuView.swift` | UI Presentation | SwiftUI popover displaying the selected drive's health gauge, lifetime writes, temperature, SMART attributes, fleet pill switcher, and quick actions. |
| `src/ui/SettingsViewModel.swift` | UI Presentation | Coordinates two-way SwiftUI bindings, launchd plist generation, alert script testing, and manages the ephemeral lifecycle of `SettingsWindowController`. |

---

## 6. Runtime View (Operational Sequences & State Machines)

### 6.1 Multi-Disk Fleet Polling Sequence
The core evaluation cycle executed periodically by `AppDelegate` or triggered on-demand via CLI flags:

```mermaid
sequenceDiagram
    autonumber
    participant Timer as Polling Timer (30s)
    participant Mon as DiskHealthMonitor
    participant Prov as IOKitTelemetryProvider
    participant Bridge as DiskHealthBridge.c
    participant Canary as CanaryProbeService
    participant Rules as StandardHealthRulePipeline
    participant Disk as AtomicFileWriter (0600)

    Timer->>Mon: evaluateAllMonitoredDisks(forceCanary, allowNotifications)
    activate Mon
    Note over Mon: Acquire engineLock
    Mon->>Prov: listAllDevices(maxCount: 32)
    Prov->>Bridge: DiskListAllDevices(&rawDevices, 32)
    Bridge-->>Prov: DiskHardwareMetrics[] (Static cache + live SMART/driver stats)
    loop For each physical drive
        Mon->>Prov: findMountPoint(forBsdName: dev.bsdName)
        Prov->>Bridge: DiskFindMountForBlockDevice() (stackFs[64] + slice resolution)
        Bridge-->>Prov: Resolved mount path (e.g. "/" or "/Volumes/T7")
        Mon->>Prov: inspectFilesystem(mountPath) (statfs + APFS purgeable space)
        alt Volume Mounted & Canary Enabled & !isSystemSleeping
            Mon->>Canary: runCanaryCheck(targetMount, force, nowTs)
            Canary-->>Mon: CanaryProbeResult (cached 300s or live 512B probe)
        end
        Mon->>Rules: evaluate(context: HealthEvaluationContext) across 12 Pure Rules
        Rules-->>Mon: HealthRuleOutcome (issues, scorePenalty, logMessages)
        Mon->>Mon: Update per-drive baseline state & evaluate scoped alert cooldowns
    end
    Mon->>Mon: Aggregate MultiDiskHealthSnapshot (worstSeverity, worstScore, avgScore)
    Mon->>Disk: Write latest_status.json & state.json (only if dirty)
    Note over Mon: Release engineLock & dispatch @Published updates to Main Thread
    deactivate Mon
```

### 6.2 Sector-Aligned Canary Probe Flowchart
The non-destructive active I/O verification algorithm implemented in `CanaryProbeService.swift`:

```mermaid
flowchart TD
    Start(["runCanaryCheck(targetMount, force, nowTs)"]) --> CacheCheck{"!force && cached < 300s?"}
    CacheCheck -- Yes --> ReturnCached(["Return Cached CanaryProbeResult"])
    CacheCheck -- No --> RootCheck{"targetMount == '/'?"}
    RootCheck -- Yes --> DataTmp["Path: ~/.config/disk-health-monitor/.disk_health_canary_<uid>"]
    RootCheck -- No --> DirectMount["Path: targetMount/.disk_health_canary_<uid>"]
    DataTmp & DirectMount --> OpenFile["open(path, O_CREAT|O_RDWR|O_NOFOLLOW|O_CLOEXEC, 0600)"]
    OpenFile --> OpenOk{"fd >= 0?"}
    OpenOk -- "No (EACCES/EPERM)" --> SelfHeal["Self-Heal: unlink() orphaned 0400 file & retry open()"]
    SelfHeal --> OpenOk2{"fd >= 0?"}
    OpenOk -- "No (EROFS)" --> ReadFallback["Fallback: opendir() + readdir() directory probe"]
    OpenOk2 -- "No (EPERM/EACCES/EROFS)" --> ReadFallback
    OpenOk2 -- "No (Other errno)" --> FailOpen(["Return ok: false, open failed"])
    OpenOk -- Yes --> SetNoCache["fcntl(fd, F_NOCACHE, 1)<br/>Allocate 4096-byte page-aligned buffer"]
    OpenOk2 -- Yes --> SetNoCache
    SetNoCache --> PWrite["pwrite(fd, alignedWriteBuf, 4096, offset 0)"]
    PWrite --> EinvalCheck{"written < 0 && errno == EINVAL?"}
    EinvalCheck -- "Yes (FAT32/exFAT)" --> DisableNoCache["fcntl(fd, F_NOCACHE, 0) & retry pwrite()"]
    EinvalCheck -- No --> CheckWrite{"written == 4096?"}
    DisableNoCache --> CheckWrite
    CheckWrite -- No --> FailWrite(["close(fd), unlink(), Return write failed"])
    CheckWrite -- Yes --> Fsync["fcntl(fd, F_FULLFSYNC) (fallback: fsync(fd))"]
    Fsync --> CheckFsync{"sync == 0?"}
    CheckFsync -- No --> FailFsync(["close(fd), unlink(), Return fsync failed"])
    CheckFsync -- Yes --> PRead["pread(fd, alignedReadBuf, 4096, offset 0) & close(fd)"]
    PRead --> Verify{"memcmp(alignedWriteBuf, alignedReadBuf, 4096) == 0?"}
    Verify -- No --> FailVerify(["unlink(), Return readback mismatch"])
    Verify -- Yes --> CheckSpike{"!ok || latencyMs > 300ms?"}
    ReadFallback --> CheckSpike
    CheckSpike -- "Yes (Pass 1)" --> RetryPass["usleep(50ms) & run 2nd confirmation pass"]
    CheckSpike -- No --> StoreCache["Store in cacheByMount[key] & Return Result"]
    RetryPass --> StoreCache
```

### 6.3 Keychain Integration State Machine
The opt-in state machine in `SecretStore.swift` guaranteeing zero unprompted security dialogs:

```mermaid
stateDiagram-v2
    [*] --> Disabled: Default Initial State
    Disabled --> Ready: User explicitly clicks "Enable Keychain" in UI (⌘,)
    Ready --> Disabled: User clicks "Disable Keychain"
    Ready --> Locked: securityd returns errSecAuthFailed or errSecUserCanceled
    Locked --> Ready: User unlocks Keychain via macOS prompt
    
    note right of Disabled
        Headless CLI and LaunchAgent daemons
        operate strictly in Disabled state.
        Secrets stored in 0600 config.json file.
        Zero modal popups guaranteed.
    end note
```

---

## 7. Deployment & Packaging View

### 7.1 Deployment Topology

```mermaid
flowchart TD
    subgraph Host["macOS Host Workstation / Server"]
        subgraph AppBundle["/Applications/DiskHealthMonitor.app"]
            MachO["Contents/MacOS/DiskHealthMonitor<br/>(Universal Mach-O Binary)"]
            Plist["Contents/Info.plist<br/>(LSUIElement = true)"]
            Resources["Contents/Resources/AppIcon.icns"]
        end

        subgraph Symlink["CLI Accessibility"]
            UsrLocal["/usr/local/bin/disk-health -> Application Mach-O"]
            RepoLink["./disk-health -> Contents/MacOS/DiskHealthMonitor"]
        end

        subgraph Daemon["launchd Service Supervision"]
            LaunchAgentPlist["~/Library/LaunchAgents/io.github.disk-health-monitor.plist"]
        end

        subgraph UserHome["~/.config/disk-health-monitor/ (Permissions: 0700)"]
            CfgJson["config.json (0600)<br/>Sanitized JSON Configuration"]
            StateJson["state.json (0600)<br/>Per-Drive Baselines & Alert Cooldowns"]
            StatusJson["latest_status.json (0600)<br/>Current Telemetry Snapshot"]
            LockFile["menubar.lock (0600)<br/>Exclusive flock File"]
            Logs["logs/health.log (0600)<br/>5 MB Rotating Event Stream"]
        end
    end

    LaunchAgentPlist -->|"Spawns on Login (--menubar)"| MachO
    UsrLocal -.-> MachO
    RepoLink -.-> MachO
    MachO --> UserHome
```

### 7.2 Release Artifacts Pipeline (`build_and_install.sh`)
When executed with the `--package` flag, `build_and_install.sh` produces verified distribution artifacts in `dist/`:
- `DiskHealthMonitor-v2.6.0-macOS-universal.dmg`: Apple Disk Image containing `DiskHealthMonitor.app` and `/Applications` symlink.
- `DiskHealthMonitor-v2.6.0-macOS-universal.zip`: Compressed application bundle.
- `disk-health-v2.6.0-cli-universal.tar.gz`: Standalone universal Mach-O CLI binary and installation helper.
- `SHA256SUMS.txt`: Cryptographic SHA-256 checksums of all release packages.

---

## 8. Cross-Cutting Concepts

### 8.1 Concurrency Architecture & Acyclic Lock Hierarchy
To prevent race conditions, deadlocks, and UI run-loop stalls without requiring Swift 6 macro plugins, the codebase enforces an **acyclic lock hierarchy**:

```mermaid
flowchart LR
    UI["Main Thread (@MainActor / AppKit RunLoop)<br/>Reads publishedSnapshot & publishedMultiSnapshot Lock-Free"]
    Debounce["SettingsViewModel.debounceLock (NSLock)"]
    Engine["DiskHealthMonitor.engineLock (NSRecursiveLock)"]
    CfgLock["ConfigManager.configLock (NSRecursiveLock)"]
    SecLock["SecretStore.lock (NSRecursiveLock)"]
    LogLock["ConfigManager.logLock (NSLock)"]
    CanaryLock["CanaryProbeService.lock (NSLock)"]
    StaticMutex["DiskHealthBridge.sStaticCacheMutex (pthread_mutex_t)"]

    UI -.->|"Async dispatch (.userInitiated)"| Engine
    Debounce --> SecLock & CfgLock
    Engine --> CfgLock
    Engine --> CanaryLock
    Engine --> LogLock
    Engine --> StaticMutex
    CfgLock --> SecLock
```

#### Concurrency Invariants
1. **No Inversion into Engine**: `ConfigManager.configLock` **never** calls into `DiskHealthMonitor`.
2. **Pre-Notification Lock Release**: `ConfigManager` always releases `configLock` **before** dispatching `notifyObjectWillChangeOnMain()`.
3. **Non-Blocking UI Drive Selection (`SYS2-02`)**: `DiskHealthMonitor.selectDashboardDrive(key:)` updates `@Published` properties synchronously on `@MainActor` and dispatches `engineLock` acquisition asynchronously to `DispatchQueue.global(qos: .userInitiated)`. This guarantees the main thread never blocks behind background I/O operations.

### 8.2 Memory Ownership Across C11 / CoreFoundation / IOKit
Every kernel resource allocated in `DiskHealthBridge.c` obeys explicit, deterministic lifecycle pairing:
- `IOServiceGetMatchingServices` / `IORegistryEntryGetChildIterator` $\rightarrow$ `IOObjectRelease(iterator)`
- `IOIteratorNext` / `IOServiceGetMatchingService` $\rightarrow$ `IOObjectRelease(entry)`
- `IORegistryEntryCreateCFProperty` $\rightarrow$ `CFRelease(propertyRef)`
- `IOCreatePlugInInterfaceForService` $\rightarrow$ `IODestroyPlugInInterface(pluginInterface)`
- `QueryInterface(..., &smartInterface)` $\rightarrow$ `(*smartInterface)->Release(smartInterface)`

### 8.3 Security & Secret Sanitization
- **Strict File Permissions**: All state files, configurations, and logs are protected by POSIX `0600` permissions (`S_IRUSR | S_IWUSR`), created via `open(path, O_CREAT | O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0600)`.
- **Symlink Traversal Prevention**: Directories and lock files employ `O_NOFOLLOW` to prevent arbitrary file truncation via malicious symlinks.
- **Automated Credential Redaction**: Telegram bot tokens (`123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11`) and Webhook URLs (`https://hooks.slack.com/services/...`) are automatically replaced with `[REDACTED_SECRET]` in logs, terminal outputs, and exported diagnostic bundles.

### 8.4 Reverse-Seek Log Rotation & UTF-8 Slicing (`SYS2-01`)
`DiagnosticExporter.readLastLogLines` implements an efficient reverse-seek algorithm:
- Reads the trailing `N` bytes of `health.log` using `seek(toFileOffset:)` without reading multi-gigabyte log files into memory.
- Reads `maxTailBytes + 1` bytes and discards the partial leading slice up to the first newline character (`\n`), ensuring that split multi-byte UTF-8 sequences are deterministically eliminated.

---

## 9. Architecture Decision Records (ADRs)

### ADR-001: Single-Binary Dual-Mode Architecture
- **Context**: Users require both a terminal-friendly headless CLI tool for scripts/launchd and an interactive Menu Bar dashboard. Maintaining two separate binaries duplicates telemetry logic, Swift runtime overhead, and release packaging.
- **Decision**: Compile a single universal Mach-O binary. If launched with CLI flags, execute synchronously and exit. If launched without flags or with `--menubar`, detach from the controlling terminal via `posix_spawn` (`POSIX_SPAWN_SETSID`), acquire `SingleInstanceLock`, and launch `NSApplication`.
- **Consequences**: Zero code duplication. Single compilation pass. Requires careful separation of main-thread UI components from headless CLI paths.

### ADR-002: Dedicated C11 IOKit Hardware Bridge
- **Context**: Swift bindings for low-level IOKit COM-style vtables (`IOCFPlugInInterface`, `IONVMeSMARTInterface`) are fragile, require complex unsafe pointer arithmetic, and suffer from struct alignment issues when reading 128-bit little-endian NVMe counters.
- **Decision**: Encapsulate all IOKit registry queries, APFS subtree pruning, and NVMe SMART decoding in a modular C11 translation unit (`DiskHealthBridge.c`) exposing a clean C interface (`DiskHealthBridge.h`).
- **Consequences**: Swift code remains clean, idiomatic, and type-safe. Low-level memory management and reference counting are isolated in C with rigorous boundary checks.

### ADR-003: Pure Functional Domain Health Rules
- **Context**: Disk health evaluation involves 12 complex rules (wear percentage, temperature, I/O errors, canary latency, SMART status). Mixing I/O side effects directly into rule evaluation impairs testability and causes flaky tests.
- **Decision**: Define the `HealthRule` protocol as a pure function: `(HealthEvaluationContext) -> HealthRuleOutcome`. Rules have zero side effects and return immutable outcomes.
- **Consequences**: The entire health evaluation engine is testable with 100% determinism via `MockTelemetryProvider` without requiring physical disk hardware or elevated permissions.

### ADR-004: Opt-In Keychain State Machine
- **Context**: In headless environments (cron, launchd, SSH), querying the macOS Keychain via `SecItemCopyMatching` can trigger an interactive system modal dialog ("DiskHealthMonitor wants to access your keychain"), hanging unattended scripts indefinitely.
- **Decision**: Implement an explicit `KeychainIntegrationState` machine in `SecretStore.swift`. Headless CLI and daemon execution operate strictly in `Disabled` mode unless the user explicitly opts in via the GUI Settings tab. Secrets are stored in `0600` config files by default.
- **Consequences**: Eliminates unprompted system popups. Preserves seamless automated execution while providing secure Keychain storage for interactive desktop users.

### ADR-005: Sector-Aligned (512B) In-Place Canary I/O Probes
- **Context**: Traditional canary probes create, write, and delete temporary files on every poll cycle, causing APFS B-tree catalog thrashing and fragmentation. Furthermore, `F_NOCACHE` requires sector-aligned buffers on non-APFS volumes (FAT32/exFAT).
- **Decision**: Execute in-place 512-byte sector-aligned `pwrite`/`pread` operations on a persistent hidden file (`.disk_health_canary_<uid>`), bypassing UBC via `fcntl(fd, F_NOCACHE, 1)` with automatic fallback to standard I/O on `EINVAL`.
- **Consequences**: Eliminates directory node churn. Provides true physical media response time measurements. Fully supports external USB FAT32/exFAT drives.

### ADR-006: Static Registry Entry ID Memoization (`sStaticCache`)
- **Context**: Traversing the IOKit registry tree on every 30-second poll to read immutable device properties (vendor, product, serial, interconnect type, link speed) consumes unnecessary CPU cycles.
- **Decision**: Implement a thread-safe 32-entry ring buffer (`sStaticCache`) in C keyed by `IORegistryEntryID`. Invariant strings are memoized, while dynamic properties (SMART, driver errors, live `IOMedia` BSD name) are always queried live.
- **Consequences**: Reduces background polling CPU usage by over 60%, maintaining $< 0.1\%$ CPU overhead while avoiding stale BSD name bugs after disk hot-swapping (`UAT2-03`).

### ADR-007: Ephemeral Settings Window Lifecycle
- **Context**: Keeping the SwiftUI Settings window and its associated view models alive in the background consumes 15–22 MB of Resident Set Size (RSS), penalizing background daemon efficiency.
- **Decision**: Implement `SettingsWindowController` with explicit `windowWillClose` deallocation (`OPT2-03`). When the user closes the Settings window (`⌘W`), the window controller, SwiftUI hosting controller, and `SettingsViewModel` are destroyed and reclaimed by ARC.
- **Consequences**: Idle daemon memory footprint remains strictly under 25 MB.

---

## 10. Quality Requirements & Verification Matrix

The system architecture is verified across 5 distinct testing tiers certifying every operational guarantee:

```mermaid
flowchart TD
    subgraph TestSuite["Automated Verification Suite (tests/run_tests.sh)"]
        T1["[1/5] C11 / IOKit Bridge Unit Tests<br/>(16 C Tests in test_disk_health_bridge.c)"]
        T2["[2/5] Swift Core Engine & Domain Unit Tests<br/>(48 Swift Tests in test_core_logic.swift)"]
        T3["[3/5] CLI Integration & Detachment Tests<br/>(14 Command-Line Flags & Session Checks)"]
        T4["[4/5] Exporters & Surface Scanner Verification<br/>(JSON, Standalone HTML, Quick F_NOCACHE Scan)"]
        T5["[5/5] Bundle Assets & Layout Integrity<br/>(AppIcon.icns, Info.plist, Logs Directory)"]
    end

    subgraph ArchitectureTiers["Certified Architectural Guarantees"]
        A1["Layer 1: IOKit Safety, APFS Pruning & 128-bit Counters"]
        A2["Layer 2 & 3: Concurrency, Pure Rules & Canary Probing"]
        A3["Layer 4: CLI Router, Process Detachment & Symlink Protection"]
        A4["Diagnostics: Reverse-Seek Log Tailer & HTML Exporter"]
        A5["Packaging: macOS Application Bundle & Code Signing"]
    end

    T1 --> A1
    T2 --> A2
    T3 --> A3
    T4 --> A4
    T5 --> A5
```

### 10.1 Verification Matrix

| Verification Stage | Test Target | Key Assertions & Scenarios | Architectural Guarantee |
| :---: | :--- | :--- | :--- |
| **Stage 1** | `test_disk_health_bridge` | Tests 1–16: Registry traversal, APFS pruning, SATA/USB vs PCIe link speed parsing, NVMe 128-bit saturation, temperature clamping (-40°C to 150°C), 64-entry static cache hit/miss. | Zero memory leaks in C, balanced `CFRelease`/`IOObjectRelease`. |
| **Stage 2** | `test_core_logic` | Tests 1–48: Pure health rules, atomic 0600 file writes, SecretStore state machine, 4096B page-aligned canary with `F_FULLFSYNC`, orphan self-healing, log secret redaction & burst deduplication, transient alert hysteresis. | Deterministic domain evaluation, acyclic lock hierarchy, thread safety. |
| **Stage 3** | CLI Integration | `--help`, `--version`, `--list-disks`, `--status`, `--all`, `--json`, `--check`, `--watch-mounts`, `--deep`, `POSIX_SPAWN_SETSID` detachment. | Dual-mode bootstrap correctness, deterministic exit status codes (`0`, `1`, `2`). |
| **Stage 4** | Exporters & Scanners | `--export-config`, `--import-config`, `--export-diagnostics`, `--export-html`, `--surface-scan quick`. | Credential masking, valid HTML/SVG generation, non-destructive media read verification. |
| **Stage 5** | Packaging Integrity | Directory structure, `assets/AppIcon.icns`, `Info.plist` bundle identifiers. | Clean macOS bundle structure and LaunchAgent compatibility. |

---

## 11. Technical Risks, Pitfalls & Optimization Roadmap

*(Authoritative Assessment by Gemini 4 Argon, Lead Systems Architect)*

### 11.1 Pitfall 1: Synchronous Polling Contention on High-Drive-Count Topologies
- **Vulnerability Mechanism**: In `DiskHealthMonitor.evaluateAllMonitoredDisks`, the engine acquires `engineLock` once and iterates sequentially over all discovered drives (`for dev in enumeratedDevices`). On multi-drive workstations (e.g., Mac Studio with 8+ external USB/Thunderbolt enclosures), if a single external drive is in a low-power sleep state, its `statfs` or `fsync` call can block for 1.5s to 3.0s.
- **Operational Blast Radius**: While `@MainActor` UI views read cached `@Published` snapshots lock-free, CLI callers or background tasks querying `currentMultiSnapshot` will wait for the entire sequential iteration to complete.
- **Mitigation & Roadmap (v2.5)**:
  - Implement **Lock Splitting**: Separate `engineLock` into a fast, non-blocking `snapshotReadLock` (held for $< 1 \mu\text{s}$ during snapshot swaps) and a `pollExecutionLock`.
  - Implement **Bounded Concurrent Probing**: Use a Swift `TaskGroup` (concurrency limit 4) to execute `statfs` and canary probes across independent physical disks in parallel before aggregating snapshots under the lock.

### 11.2 Pitfall 2: USB-to-NVMe Bridge SAT/SCSI Pass-Through Blindness
- **Vulnerability Mechanism**: `DiskHealthBridge.c` queries NVMe SMART via `kIONVMeSMARTUserClientTypeID`. While internal Apple SSDs and Thunderbolt PCIe enclosures expose native NVMe controllers, many USB 3.2 enclosures (Realtek RTL9210, ASMedia ASM2362, JMicron JMS583) bridge the NVMe drive over **USB Attached SCSI (UASP / `IOBlockStorageServices`)**. On these bridges, `IOCreatePlugInInterfaceForService` returns `kIOReturnUnsupported`, setting `smartValid = false`.
- **Operational Blast Radius**: The monitor continues tracking filesystem health, I/O error counters, link speeds, and canary probes, but cannot read temperature or percentage used without SCSI pass-through.
- **Mitigation & Roadmap (v2.5)**:
  - Add an optional secondary probe in `DiskHealthBridge.c` using `IOSCSIPeripheralDeviceType00` / `SCSITaskUserClient` issuing a non-destructive SCSI / SAT ATA PASS-THROUGH or NVMe Admin Pass-Through CDB (`0x85` / `0xA2`) when native NVMe clients are unavailable.

### 11.3 Pitfall 3: `sStaticCache` Ring-Buffer Thrashing on >32 Virtual Disks
- **Vulnerability Mechanism**: `DiskHealthBridge.c` defines `MAX_STATIC_CACHE_ENTRIES 32`. In environments where developers or CI pipelines attach $> 32$ virtual disk images (`.dmg` or Xcode simulator runtimes), `DiskListAllDevices` cycles through $> 32$ entries in a single pass, evicting entries from the FIFO ring buffer on every poll cycle.
- **Operational Blast Radius**: No functional corruption occurs (evicted devices simply re-query `IORegistryEntryCreateCFProperty`), but CPU memoization efficiency drops.
- **Mitigation**:
  - Filter out virtual disk image drivers (`AppleDiskImageDevice`, `IOHDIXHDDriveOutKernel`) before caching, or expand `MAX_STATIC_CACHE_ENTRIES` to 64.

### 11.4 Pitfall 4: LaunchAgent `KeepAlive` Interaction with Manual Quit (`⌘Q`)
- **Vulnerability Mechanism**: `build_and_install.sh` and `SettingsViewModel` configure `KeepAlive = ["SuccessfulExit": false]`. When a user quits via Menu Bar (`⌘Q`), `NSApplication.shared.terminate(nil)` exits with status `0` (`SuccessfulExit == true`), so `launchd` properly leaves the process stopped. However, if a process crash or unhandled `SIGTERM` produces a non-zero exit code, `launchd` immediately respawns the daemon.
- **Mitigation**: Verified and documented in `SettingsViewModel.swift` and `src/main.swift` signal handlers (`exit(0)` on clean termination).

### 11.5 Pitfall 5: Uninterruptible Kernel Sleep (`D` State) on Dying External Enclosures
- **Vulnerability Mechanism**: When an external USB or Thunderbolt SSD controller suffers a firmware hang or NAND controller lockup prior to bus disconnect, the mount point remains visible in the VFS table. Calls to `statfs(2)`, `getattrlist(2)`, or `fsync(2)` enter an uninterruptible kernel sleep (`D` state) in Darwin VFS/IOKit until the driver times out (30–60s).
- **Mitigation & Roadmap (v2.5)**: Wrap per-volume filesystem inspection in an asynchronous worker queue with per-device circuit breakers (3s timeout) marking the volume as `.degraded("I/O Timeout - Controller Unresponsive")` without blocking healthy drives.

### 11.6 Pitfall 6: macOS Dark Wake (`kIOPMSystemPowerStateCapabilityDisk`) Race Window
- **Vulnerability Mechanism**: During macOS Power Nap / Dark Wake, the kernel wakes the CPU and network without posting `NSWorkspace.didWakeNotification`. If a background poll fires while external buses are powered down, active `F_NOCACHE` writes can force external drives to spin up unnecessarily or fail with transient `ENXIO`/`EIO`.
- **Mitigation & Roadmap (v2.5)**: Verify active display/user session via `CGSessionCopyCurrentDictionary` or `IOPMCopySystemPowerSettings` before triggering active canary writes on external buses, and enforce an 8-second post-wake settle grace period.

### 11.7 Pitfall 7: APFS Purgeable Space Query Overhead (`getattrlist`) on Non-APFS Mounts
- **Vulnerability Mechanism**: Third-party virtual block devices (e.g. VeraCrypt, macFUSE, iSCSI) register `/dev/diskN` block devices. Calling APFS-specific `getattrlist(ATTR_VOL_SPACEUSED)` on non-APFS mounts can cause slow user-space daemon round-trips.
- **Mitigation**: In `IOKitTelemetryProvider.inspectFilesystem`, strictly gate APFS purgeable space syscalls behind `statfs.f_fstypename == "apfs"`.

### 11.8 Pitfall 8: `pkill -P` PID Recycling Window in `VolumeVerifierService`
- **Vulnerability Mechanism**: If `diskutil verifyVolume` times out at $t = 180\text{s}$ and exits right before `pkill -P <pid>`, Darwin's cyclic PID allocator could theoretically reassign the PID in high-churn environments.
- **Mitigation**: Spawn `diskutil` inside a dedicated Process Group (`POSIX_SPAWN_SETPGROUP`) and terminate the process group via `kill(-pgid, SIGTERM)` while the process handle remains un-waited.

### 11.9 Pitfall 9: macOS 15+ (Sequoia) Local Network Privacy & TCC Enforcement
- **Vulnerability Mechanism**: Beginning in macOS 15, processes communicating with local network endpoints (`.local` or LAN IP addresses for Webhooks/Prometheus) may trigger TCC security prompts if invoked outside the `.app` bundle or missing explicit descriptions.
- **Mitigation**: Add `NSLocalNetworkUsageDescription` to `Info.plist` in `build_and_install.sh`.

---

## 12. Glossary & References

### 12.1 Glossary of Terms
- **APFS Physical Store**: The underlying raw block storage partition (`Apple_APFS`) hosting an APFS container scheme and its virtual volumes.
- **BSD Name**: The Darwin kernel device identifier assigned to storage nodes (e.g., `disk0`, `disk1s1`).
- **Canary Probe**: A targeted, non-destructive write/read/verify I/O operation designed to detect silent filesystem freezes, write-blocking, and I/O latency spikes before user workflows fail.
- **Data Unit (NVMe)**: Under NVMe Base Specification 1.4+, 1 Data Unit equals 1,000 sectors of 512 bytes each (512,000 bytes).
- **Dark Wake**: A macOS power state where the kernel and CPU wake for background maintenance (e.g. Time Machine, Power Nap) while displays and external drive buses remain suspended.
- **F_NOCACHE**: A POSIX `fcntl(2)` flag instructing the Darwin kernel to bypass the Unified Buffer Cache (UBC) for direct media I/O.
- **IOBlockStorageDevice**: The primary IOKit class representing physical block storage hardware.
- **IONVMeSMARTUserClient**: The Apple IOKit user-client interface for querying NVMe health logs, error counters, and temperature sensors.
- **LSUIElement**: A macOS `Info.plist` key indicating that the application runs as an agent without appearing in the Dock or the Cmd-Tab application switcher.
- **Percentage Used**: An NVMe endurance metric representing vendor-declared wear ($0\% = \text{new}$, $\ge 100\% = \text{exceeded warranty threshold}$).
- **POH (Power-On Hours)**: Total cumulative hours the drive has been in an active operational power state.
- **TBW (Total Bytes Written)**: Cumulative terabytes written to non-volatile flash storage over the life of the drive.

### 12.2 References
1. **arc42 Architecture Template**: [https://arc42.org](https://arc42.org)
2. **C4 Model for Visualizing Software Architecture**: [https://c4model.com](https://c4model.com)
3. **NVM Express Base Specification Revision 2.0**: Section 5.14.1.2 ("SMART / Health Information Log").
4. **Apple IOKit Fundamentals**: Apple Developer Documentation, Kernel & Device Drivers.
5. **ISO/IEC 25010:2011**: Systems and software engineering — Systems and software Quality Requirements and Evaluation (SQuaRE).
