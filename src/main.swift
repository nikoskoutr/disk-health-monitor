// ============================================================================
// File: main.swift
// Module: Layer 4 (Presentation / CLI Router & Entrypoint)
// Purpose: Main Mach-O entrypoint providing dual-mode routing: synchronous headless
//          CLI command execution or POSIX_SPAWN_SETSID terminal detachment into Menu Bar.
// Concurrency: Main thread; signal handlers trap SIGINT and SIGTERM.
// ============================================================================

import Foundation
import AppKit
import SwiftUI
import Darwin

// MARK: - CLI Argument Processing & Entry Point

func printUsage() {
    print("""
    Universal macOS Disk Health Monitor & Telemetry Agent [\(kAppArchitecture)]
    Version: \(kAppVersion) (Build \(kAppBuildNumber))
    Usage: disk-health [OPTIONS]

    Commands & Modes:
      --status              Print human-readable disk health summary and active issues
      --check               Run a single background check cycle and send alerts
      --all                 Monitor and evaluate all connected physical disks simultaneously
      --watch-mounts        Run a check triggered by a mount event
      --deep                Include filesystem verification (diskutil verifyVolume)
      --list-disks          List all detected block storage devices, buses, and SMART status
      --json                Dump current telemetry snapshot as pretty-printed JSON
      --export-config       Export current configuration as sanitized JSON (--unmasked for secrets)
      --import-config <file> Import and apply configuration profile from a JSON file
      --export-diagnostics  Generate comprehensive JSON diagnostic report in logs/ (or [path])
      --export-html         Generate standalone HTML health & RMA report in logs/ (or [path])
      --surface-scan [mode] Run non-destructive F_NOCACHE surface scan (modes: quick, standard, full)
      --verify              Run volume filesystem verification (diskutil verifyVolume)
      --list-rules          List all configured 'When X, Do Y' automation rules
      --simulate-rule [id]  Simulate an automation rule in dry-run mode against a synthetic snapshot
      --top-io              Sample active processes performing disk I/O via Darwin libproc
      --test-alert-script   Test execution of the configured custom alert shell script
      --send-report         Dispatch on-demand HTML health report to Telegram
      --menubar             Launch the macOS Menu Bar status item application (default)
      --version, -v         Display application version and target binary architecture
      --help, -h            Show this help manual

    Target Overrides:
      --volume <path>       Specify target mount path to monitor (e.g., /Volumes/MyDrive or /)
      --device <query>      Specify target device BSD name (e.g., disk4), product name, or serial
      --notify              When used with --status or --verify, dispatch alerts if unhealthy

    Configuration & Environment:
      Architecture:         \(kAppArchitecture)
      Configuration files:  ~/.config/disk-health-monitor/config.json
      Logs directory:       logs/ (or ~/.config/disk-health-monitor/logs)
      Environment variables: DISK_HEALTH_VOLUME, DISK_HEALTH_DEVICE, TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID
    """)
}

func parseCommandLine() {
    let args = CommandLine.arguments

    // Validate known CLI options (CLI-01) while ignoring macOS LaunchServices parameters (MISSED-05)
    let recognizedFlags: Set<String> = [
        "--all", "--volume", "--device", "--version", "-v", "--help", "-h",
        "--export-config", "--unmasked", "--include-secrets", "--import-config",
        "--export-diagnostics", "--export-html", "--surface-scan",
        "--list-rules", "--simulate-rule", "--top-io",
        "--test-alert-script", "--list-disks", "--json", "--cli", "--status",
        "--check", "--watch-mounts", "--deep", "--notify", "--notify-if-unhealthy",
        "--verify", "--send-report", "--menubar"
    ]

    var skipNext = false
    for i in 1..<args.count {
        if skipNext {
            skipNext = false
            continue
        }
        let arg = args[i]
        if arg == "--volume" || arg == "--device" || arg == "--import-config" || arg == "--export-diagnostics" || arg == "--export-html" || arg == "--surface-scan" || arg == "--simulate-rule" {
            if i + 1 < args.count && !args[i + 1].hasPrefix("-") {
                skipNext = true
            }
            continue
        }
        if arg.hasPrefix("--surface-scan=") || arg.hasPrefix("--simulate-rule=") {
            continue
        }
        if arg.hasPrefix("-") {
            if arg.hasPrefix("-psn_") || arg.hasPrefix("-NS") || arg.hasPrefix("-Apple") {
                continue
            }
            if !recognizedFlags.contains(arg) {
                fputs("Error: Unrecognized option '\(arg)'. Use --help for usage information.\n", stderr)
                exit(64)
            }
        }
    }

    // Process override flags first (in-memory overrides for this invocation)
    if args.contains("--all") {
        ConfigManager.shared.overrideMonitorAll(true)
    }

    for i in 0..<args.count {
        if args[i] == "--volume" {
            guard i + 1 < args.count, !args[i + 1].hasPrefix("-") else {
                fputs("Error: --volume requires a mount path argument (e.g., --volume /Volumes/MyDrive).\n", stderr)
                exit(1)
            }
            ConfigManager.shared.overrideTarget(volumePath: args[i + 1], deviceQuery: nil)
        } else if args[i] == "--device" {
            guard i + 1 < args.count, !args[i + 1].hasPrefix("-") else {
                fputs("Error: --device requires a device query argument (e.g., --device disk4).\n", stderr)
                exit(1)
            }
            ConfigManager.shared.overrideTarget(volumePath: nil, deviceQuery: args[i + 1])
        }
    }

    if args.contains("--version") || args.contains("-v") {
        print("Universal Disk Health Monitor v\(kAppVersion) (\(kAppArchitecture))")
        exit(0)
    }

    if args.contains("--help") || args.contains("-h") {
        printUsage()
        exit(0)
    }

    if args.contains("--export-config") {
        let unmasked = args.contains("--unmasked") || args.contains("--include-secrets")
        let json = ConfigManager.shared.exportSanitizedConfigJSON(includeSecrets: unmasked)
        print(json)
        exit(0)
    }

    if args.contains("--import-config") {
        var inPath: String? = nil
        for i in 0..<args.count {
            if args[i] == "--import-config" && i + 1 < args.count && !args[i + 1].hasPrefix("-") {
                inPath = args[i + 1]
                break
            }
        }
        guard let path = inPath else {
            fputs("Error: --import-config requires a path to a configuration JSON file.\n", stderr)
            exit(1)
        }
        let url = URL(fileURLWithPath: (path as NSString).standardizingPath)
        if ConfigManager.shared.importConfigFile(at: url) {
            print("Configuration imported successfully from: \(url.path)")
            exit(0)
        } else {
            fputs("Error: Failed to import configuration from \(url.path)\n", stderr)
            exit(1)
        }
    }

    if args.contains("--export-diagnostics") {
        var outPath: String? = nil
        for i in 0..<args.count {
            if args[i] == "--export-diagnostics" && i + 1 < args.count && !args[i + 1].hasPrefix("-") {
                outPath = args[i + 1]
                break
            }
        }
        if let savedPath = DiagnosticExporter.shared.saveDiagnosticReportToFile(at: outPath) {
            print("Diagnostic report exported successfully: \(savedPath)")
            exit(0)
        } else {
            fputs("Failed to export diagnostic report.\n", stderr)
            exit(1)
        }
    }

    if args.contains("--export-html") {
        var outPath: String? = nil
        for i in 0..<args.count {
            if args[i] == "--export-html" && i + 1 < args.count && !args[i + 1].hasPrefix("-") {
                outPath = args[i + 1]
                break
            }
        }
        if let savedPath = DiagnosticExporter.shared.saveDiagnosticReportHTMLToFile(at: outPath) {
            print("HTML health report exported successfully: \(savedPath)")
            exit(0)
        } else {
            fputs("Failed to export HTML health report.\n", stderr)
            exit(1)
        }
    }

    if let scanIdx = args.firstIndex(where: { $0 == "--surface-scan" || $0.hasPrefix("--surface-scan=") }) {
        var selectedMode: DiskHealthMonitor.SurfaceScanMode = .quick
        let arg = args[scanIdx]
        if arg.hasPrefix("--surface-scan=") {
            let val = String(arg.dropFirst("--surface-scan=".count)).lowercased()
            if let m = DiskHealthMonitor.SurfaceScanMode(rawValue: val) {
                selectedMode = m
            } else {
                fputs("Unknown surface scan mode '\(val)'. Valid modes: quick, standard, full\n", stderr)
                exit(1)
            }
        } else if scanIdx + 1 < args.count && !args[scanIdx + 1].hasPrefix("-") {
            let val = args[scanIdx + 1].lowercased()
            if let m = DiskHealthMonitor.SurfaceScanMode(rawValue: val) {
                selectedMode = m
            } else {
                fputs("Unknown surface scan mode '\(val)'. Valid modes: quick, standard, full\n", stderr)
                exit(1)
            }
        }

        let isTTY = isatty(STDERR_FILENO) != 0
        let res = DiskHealthMonitor.shared.runSurfaceReadScan(mode: selectedMode) { prog in
            guard isTTY && selectedMode != .quick else { return }
            let pct = Int((prog.fractionCompleted * 100.0).rounded())
            let etaStr: String
            if let eta = prog.estimatedRemainingSec, eta.isFinite {
                etaStr = String(format: "ETA %.0fs", eta)
            } else {
                etaStr = "ETA --"
            }
            let line = String(
                format: "\r\u{1B}[KScanning [%@]: %3d%% | %d files | %@ | %.1f MB/s | Errors: %d | %@",
                selectedMode.shortLabel,
                pct,
                prog.filesScanned,
                formatBytes(prog.bytesScanned),
                prog.throughputMBps,
                prog.readErrors,
                etaStr
            )
            fputs(line, stderr)
            fflush(stderr)
        }
        if isTTY && selectedMode != .quick {
            fputs("\r\u{1B}[K", stderr)
            fflush(stderr)
        }
        print("Surface Read Validation: \(res.summary)")
        exit(res.ok ? 0 : 2)
    }

    if args.contains("--test-alert-script") {
        let (ok, summary) = DiskHealthMonitor.shared.testAlertScript()
        print(summary)
        exit(ok ? 0 : 1)
    }

    if args.contains("--list-rules") {
        let cfg = ConfigManager.shared.currentConfig
        print("================================================================================")
        print("  DECLARATIVE AUTOMATION RULES (Engine: \(cfg.enableActionRulesEngine ? "ENABLED" : "DISABLED"))")
        print("================================================================================")
        if cfg.actionRules.isEmpty {
            print("  No automation rules configured.")
        }
        for (idx, rule) in cfg.actionRules.enumerated() {
            let statusStr = rule.isEnabled ? "ACTIVE" : "DISABLED"
            let dryStr = rule.dryRunOnly ? " [DRY-RUN]" : ""
            print("  [\(idx + 1)] \(rule.name) (id: \(rule.id)) — \(statusStr)\(dryStr)")
            print("      WHEN: \(rule.conditionSummary)")
            print("      ON:   \(rule.scope.displayName) • Sustained: \(rule.requiredConsecutivePolls) poll(s) • Cooldown: \(Int(rule.cooldownSeconds))s")
            print("      DO:   \(rule.actionType.displayName)")
        }
        print("================================================================================")
        exit(0)
    }

    if let simIdx = args.firstIndex(where: { $0 == "--simulate-rule" || $0.hasPrefix("--simulate-rule=") }) {
        let cfg = ConfigManager.shared.currentConfig
        guard !cfg.actionRules.isEmpty else {
            fputs("Error: No automation rules configured to simulate.\n", stderr)
            exit(1)
        }
        var query = "1"
        let arg = args[simIdx]
        if arg.hasPrefix("--simulate-rule=") {
            query = String(arg.dropFirst("--simulate-rule=".count))
        } else if simIdx + 1 < args.count && !args[simIdx + 1].hasPrefix("-") {
            query = args[simIdx + 1]
        }

        var targetRule: ActionRule? = nil
        if let oneBasedIdx = Int(query), oneBasedIdx >= 1 && oneBasedIdx <= cfg.actionRules.count {
            targetRule = cfg.actionRules[oneBasedIdx - 1]
        } else {
            targetRule = cfg.actionRules.first(where: {
                $0.id.caseInsensitiveCompare(query) == .orderedSame ||
                $0.name.localizedCaseInsensitiveContains(query)
            })
        }

        guard let rule = targetRule else {
            fputs("Error: Rule '\(query)' not found. Use --list-rules to view available rule indices or IDs.\n", stderr)
            exit(1)
        }

        let rec = DiskHealthMonitor.shared.simulateActionRule(rule, executeLive: false, persistAuditRecord: false)
        print("================================================================================")
        print("  AUTOMATION RULE DRY-RUN SIMULATION")
        print("================================================================================")
        print("  Rule:    \(rec.ruleName) (\(rec.ruleId))")
        print("  Target:  \(rec.driveDisplayName)")
        print("  Trigger: \(rec.triggerReason)")
        print("  Action:  \(rec.actionType.displayName)")
        print("  Status:  \(rec.status.rawValue)")
        print("  Result:  \(rec.outputDetail)")
        print("================================================================================")
        exit(0)
    }

    if args.contains("--top-io") {
        let culprits = ProcessIoInspector.shared.sampleActiveCulpritsWindow(durationSec: 0.35, topN: 8)
        print("================================================================================")
        print("  TOP ACTIVE DISK I/O PROCESSES (Darwin libproc rusage_info_v4)")
        print("================================================================================")
        if culprits.isEmpty {
            print("  No active disk I/O processes detected.")
        } else {
            for (idx, p) in culprits.enumerated() {
                print("  [\(idx + 1)] \(p.formattedSummary)")
            }
        }
        print("================================================================================")
        exit(0)
    }

    if args.contains("--list-disks") {
        var devices = [DiskHardwareMetrics](repeating: DiskHardwareMetrics(), count: 32)
        let count = DiskListAllDevices(&devices, 32)
        print("================================================================================")
        print("  DETECTED STORAGE DEVICES (\(count) Found)")
        print("================================================================================")
        if count == 0 {
            print("  No storage devices found.")
        }
        for i in 0..<Int(count) {
            let d = devices[i]
            let prod = cStringToSwift(d.productName)
            let vendor = cStringToSwift(d.vendorName)
            let bsd = cStringToSwift(d.bsdName)
            let bus = cStringToSwift(d.interconnectType)
            let loc = d.isInternal ? "Internal" : "External"
            let smart = d.smartValid ? "SMART Ready (\(d.temperatureCelsius)°C)" : "No NVMe SMART"
            let tbw = d.smartValid ? String(format: "%.2f TBW", Double(d.dataUnitsWritten) * 512000.0 / 1e12) : "N/A"
            let serial = cStringToSwift(d.serialNumber)

            let name = "\(vendor) \(prod)".trimmingCharacters(in: .whitespaces).padding(toLength: 30, withPad: " ", startingAt: 0)
            let bsdPad = bsd.padding(toLength: 8, withPad: " ", startingAt: 0)
            let busPad = bus.padding(toLength: 12, withPad: " ", startingAt: 0)
            let locPad = loc.padding(toLength: 8, withPad: " ", startingAt: 0)
            let serPad = (serial.isEmpty ? "N/A" : serial).padding(toLength: 25, withPad: " ", startingAt: 0)
            let smartPad = smart.padding(toLength: 20, withPad: " ", startingAt: 0)

            print(" [\(String(format: "%02d", i))] \(name) | BSD: \(bsdPad) | \(busPad) | \(locPad)")
            print("      Serial: \(serPad) | SMART: \(smartPad) | Lifespan: \(tbw)")
        }
        print("================================================================================")
        exit(0)
    }

    if args.contains("--json") {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let isMultiJson = args.contains("--all") || ConfigManager.shared.currentConfig.monitorAllDisks || ConfigManager.shared.currentConfig.monitoredTargets.count > 1
        if isMultiJson {
            let multi = DiskHealthMonitor.shared.evaluateAllMonitoredDisks(forceCanary: true, allowNotifications: false, persistState: false)
            if let data = try? encoder.encode(multi), let str = String(data: data, encoding: .utf8) {
                print(str)
            }
            exit(Int32(multi.overallSeverity.rank))
        } else {
            let snap = DiskHealthMonitor.shared.evaluateHealth(forceCanary: true, allowNotifications: false, persistState: false)
            if let data = try? encoder.encode(snap), let str = String(data: data, encoding: .utf8) {
                print(str)
            }
            exit(Int32(snap.overallSeverity.rank))
        }
    }

    let isCheckMode = args.contains("--cli") || args.contains("--status") || args.contains("--check") || args.contains("--watch-mounts") || args.contains("--deep") || args.contains("--all")
    if isCheckMode {
        let notify = args.contains("--notify") || args.contains("--notify-if-unhealthy") || args.contains("--check") || args.contains("--watch-mounts")
        if args.contains("--deep") {
            let sem = DispatchSemaphore(value: 0)
            DiskHealthMonitor.shared.runVolumeVerification(sendTelegram: notify) { _, _ in
                sem.signal()
            }
            sem.wait()
        }

        let isMulti = args.contains("--all") || ConfigManager.shared.currentConfig.monitorAllDisks || ConfigManager.shared.currentConfig.monitoredTargets.count > 1
        if isMulti {
            let multi = DiskHealthMonitor.shared.evaluateAllMonitoredDisks(forceCanary: true, allowNotifications: notify, persistState: notify)
            print("============================================================")
            print("  \(multi.overallSeverity.emoji) FLEET DISK HEALTH MONITOR — \(multi.overallSeverity.rawValue) (Worst: \(multi.worstHealthScore)/100, Avg: \(multi.averageHealthScore)/100) [\(multi.disks.count) Disks]")
            print("============================================================")
            for (idx, snap) in multi.disks.enumerated() {
                print("  [\(idx + 1)/\(multi.disks.count)] \(snap.overallSeverity.emoji) \(snap.vendorName) \(snap.productName) (\(snap.bsdName.isEmpty ? "offline" : snap.bsdName)) — Score: \(snap.healthScore)%")
                print("      Mount    : \(snap.isMounted ? "\(snap.mountPoint) (\(snap.filesystemType), \(snap.isReadOnly ? "RO" : "RW"))" : "UNMOUNTED")")
                if snap.smartValid {
                    print(String(format: "      SMART    : %d°C | Wear: %d%% Left | TBW: %.2f TB | Unsafe: %llu", snap.temperatureCelsius, snap.lifeRemainingPercent, snap.totalTerabytesWritten, snap.unsafeShutdowns))
                }
                if snap.statsValid {
                    print(String(format: "      IO Stats : Read: %@, Write: %@ | Latency: %.2f ms R / %.2f ms W", formatBytes(snap.sessionBytesRead), formatBytes(snap.sessionBytesWritten), snap.avgReadLatencyMs, snap.avgWriteLatencyMs))
                }
                if !snap.issues.isEmpty {
                    for issue in snap.issues {
                        print("      \(issue.severity.emoji) [\(issue.code)] \(issue.title): \(issue.detail)")
                    }
                }
                if idx < multi.disks.count - 1 {
                    print("  ----------------------------------------------------------")
                }
            }
            print("============================================================")
            if notify {
                DiskHealthMonitor.shared.waitForPendingNotifications(timeout: 16.0)
            }
            exit(Int32(multi.overallSeverity.rank))
        } else {
            let snap = DiskHealthMonitor.shared.evaluateHealth(forceCanary: true, allowNotifications: notify, persistState: notify)

            print("============================================================")
            print("  \(snap.overallSeverity.emoji) DISK HEALTH MONITOR — \(snap.overallSeverity.rawValue) (Score: \(snap.healthScore)/100) [\(kAppArchShort)]")
            print("============================================================")
            print("  Device         : \(snap.vendorName) \(snap.productName) (\(snap.bsdName.isEmpty ? "offline" : snap.bsdName))")
            print("  Interconnect   : \(snap.interconnectType) (\(snap.isInternal ? "Internal" : "External")) • \(snap.linkSpeedFormatted)")
            print("  Serial Number  : \(snap.serialNumber.isEmpty ? "N/A" : snap.serialNumber)")
            print("  Mount Status   : \(snap.isMounted ? "Mounted at \(snap.mountPoint) (\(snap.isReadOnly ? "READ-ONLY" : "R/W")) [\(snap.filesystemType)]" : "UNMOUNTED")")
            if snap.isMounted {
                let purgeableSuffix = snap.purgeableBytes > 0 ? " [Purgeable: \(formatBytes(snap.purgeableBytes))]" : ""
                print(String(format: "  Capacity       : %@ used / %@ free (%.1f%% of %@)%@",
                             formatBytes(snap.usedBytes), formatBytes(snap.freeBytes), snap.usedPercent, formatBytes(snap.totalBytes), purgeableSuffix))
            }
            if snap.smartValid {
                let cfg = ConfigManager.shared.currentConfig
                print("  Temperature    : \(snap.temperatureCelsius)°C (Peak: \(snap.peakTemperatureCelsius)°C | Warn: \(cfg.tempWarningCelsius)°C | Crit: \(cfg.tempCriticalCelsius)°C)")
                print("  SSD Lifespan   : \(snap.lifeRemainingPercent)% Remaining (Percentage Used: \(snap.percentageUsed)%, Spare: \(snap.availableSpare)% / Thresh: \(snap.availableSpareThreshold)%)")
                print(String(format: "  Lifetime I/O   : %.2f TB Written (TBW) / %.2f TB Read", snap.totalTerabytesWritten, snap.totalTerabytesRead))
                print("  SMART Counters : Power On: \(snap.powerOnHours)h (\(snap.powerOnHours / 24)d) | Cycles: \(snap.powerCycles) | Unsafe Shutdowns: \(snap.unsafeShutdowns)")
                print("  SMART Errors   : Critical Warning: 0x\(String(format: "%02X", snap.criticalWarning)) | Media Errors: \(snap.mediaErrors) | Error Log: \(snap.errorInfoLogEntries)")
            }
            if snap.statsValid {
                print(String(format: "  Driver Stats   : Errors: %llu R / %llu W | Retries: %llu R / %llu W | Avg Latency: %.2f ms R / %.2f ms W",
                             snap.errorsRead, snap.errorsWritten, snap.retriesRead, snap.retriesWritten, snap.avgReadLatencyMs, snap.avgWriteLatencyMs))
            }
            if ConfigManager.shared.currentConfig.enableActiveCanary {
                print(String(format: "  I/O Canary     : %@", snap.canaryOk ? String(format: "PASSED (%.2f ms write+fsync+read)", snap.canaryLatencyMs) : "FAILED (\(snap.canaryError))"))
            }
            print("  File System    : \(snap.lastVerifyResult)")
            if !snap.issues.isEmpty {
                print("------------------------------------------------------------")
                print("  Active Issues:")
                for issue in snap.issues {
                    print("   \(issue.severity.emoji) [\(issue.code)] \(issue.title): \(issue.detail)")
                }
            }
            print("============================================================")
            if notify {
                DiskHealthMonitor.shared.waitForPendingNotifications(timeout: 16.0)
            }
            exit(Int32(snap.overallSeverity.rank))
        }
    }

    if args.contains("--send-report") {
        let snap = DiskHealthMonitor.shared.evaluateHealth(forceCanary: true, allowNotifications: false, persistState: false)
        let html = TelegramNotifier.shared.formatReportHTML(snapshot: snap, title: "Disk Health Monitor Status Report")
        let ok = TelegramNotifier.shared.sendMessage(htmlText: html, disableNotification: false)
        print(ok ? "Telegram health report sent successfully." : "Failed to send Telegram health report.")
        exit(ok ? 0 : 1)
    }

    if args.contains("--verify") || args.contains("--verify-volume") || args.contains("--verify-apfs") {
        let sem = DispatchSemaphore(value: 0)
        var verifyOk = false
        DiskHealthMonitor.shared.runVolumeVerification(sendTelegram: args.contains("--notify")) { ok, summary in
            print("Volume Verification: \(summary)")
            verifyOk = ok
            sem.signal()
        }
        sem.wait()
        exit(verifyOk ? 0 : 1)
    }

    // Default: Run macOS Menu Bar GUI App
    // Always ignore SIGHUP in GUI mode so closing a parent terminal never kills the Menu Bar agent.
    signal(SIGHUP, SIG_IGN)

    // If launched interactively from a controlling terminal (e.g. user ran ./disk-health or double-clicked
    // the CLI binary in Finder), detach cleanly into a background session so the terminal does not stay blocked
    // and closing the terminal never terminates the Menu Bar app.
    detachFromControllingTerminalIfNeeded()

    if !SingleInstanceLock.shared.tryAcquire() {
        ConfigManager.shared.log("Another Menu Bar instance of Disk Health Monitor is already running; exiting duplicate instance cleanly.")
        exit(0)
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}

func isHeadlessCLIMode(args: [String]) -> Bool {
    let cliFlags: Set<String> = [
        "--version", "-v", "--help", "-h",
        "--export-config", "--import-config",
        "--export-diagnostics", "--export-html",
        "--surface-scan", "--test-alert-script", "--list-disks", "--json",
        "--cli", "--status", "--check", "--watch-mounts", "--deep", "--all",
        "--send-report", "--verify", "--verify-volume", "--verify-apfs"
    ]
    for arg in args.dropFirst() {
        if cliFlags.contains(arg) || arg.hasPrefix("--surface-scan") {
            return true
        }
    }
    return false
}

func resolveAppBundleExecutableURL() -> (bundleURL: URL, executableURL: URL)? {
    let rawArg0 = CommandLine.arguments.first ?? ""
    var candidateExecURL: URL? = nil

    if !rawArg0.isEmpty {
        if rawArg0.hasPrefix("/") {
            candidateExecURL = URL(fileURLWithPath: rawArg0)
        } else {
            let cwd = FileManager.default.currentDirectoryPath
            candidateExecURL = URL(fileURLWithPath: cwd).appendingPathComponent(rawArg0)
        }
    }
    if let cand = candidateExecURL, !FileManager.default.fileExists(atPath: cand.path) {
        candidateExecURL = Bundle.main.executableURL
    }

    guard let execURL = candidateExecURL else { return nil }
    let resolvedExec = execURL.resolvingSymlinksInPath().standardizedFileURL
    let path = resolvedExec.path
    if let range = path.range(of: ".app/Contents/MacOS/") {
        let bundlePath = String(path[..<range.upperBound]).replacingOccurrences(of: "/Contents/MacOS/", with: "")
        let bundleURL = URL(fileURLWithPath: bundlePath)
        if FileManager.default.isExecutableFile(atPath: path) {
            return (bundleURL, resolvedExec)
        }
    }
    return nil
}

func spawnDetachedSessionProcess(executablePath: String, arguments: [String], environment: [String: String]) -> Bool {
    var fileActions: posix_spawn_file_actions_t? = nil
    var attr: posix_spawnattr_t? = nil
    guard posix_spawn_file_actions_init(&fileActions) == 0 else { return false }
    defer { posix_spawn_file_actions_destroy(&fileActions) }
    guard posix_spawnattr_init(&attr) == 0 else { return false }
    defer { posix_spawnattr_destroy(&attr) }

    // Create a brand-new POSIX session (setsid) in the child so it has no controlling terminal
    // and cannot receive SIGHUP/SIGTERM when the parent Terminal window is closed or killed.
    _ = posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

    _ = posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    _ = posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
    _ = posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)

    var argvStrings = [executablePath]
    if arguments.count > 1 {
        argvStrings.append(contentsOf: arguments.dropFirst())
    }
    var cArgs: [UnsafeMutablePointer<CChar>?] = argvStrings.map { strdup($0) }
    cArgs.append(nil)
    defer {
        for ptr in cArgs {
            if let ptr = ptr { free(ptr) }
        }
    }

    var envStrings: [String] = []
    for (k, v) in environment {
        envStrings.append("\(k)=\(v)")
    }
    var cEnv: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) }
    cEnv.append(nil)
    defer {
        for ptr in cEnv {
            if let ptr = ptr { free(ptr) }
        }
    }

    var childPid: pid_t = 0
    let spawnRes = executablePath.withCString { execCStr in
        posix_spawn(&childPid, execCStr, &fileActions, &attr, &cArgs, &cEnv)
    }
    return (spawnRes == 0 && childPid > 0)
}

func detachFromControllingTerminalIfNeeded() {
    let env = ProcessInfo.processInfo.environment
    // Do not detach if already detached, or if explicitly disabled, or in test sandbox
    if env["DISK_HEALTH_DETACHED"] == "1" || env["DISK_HEALTH_NO_DETACH"] == "1" {
        return
    }
    if env["DISK_HEALTH_CONFIG_DIR"] != nil && env["DISK_HEALTH_FORCE_DETACH_TEST"] != "1" {
        return
    }

    let hasTTY = (isatty(STDIN_FILENO) == 1 || isatty(STDOUT_FILENO) == 1 || isatty(STDERR_FILENO) == 1)
    let hasTermEnv = (env["TERM_PROGRAM"] != nil || env["TERM"] != nil || env["SSH_TTY"] != nil)
    guard hasTTY || hasTermEnv else { return }

    let targetExecPath: String
    if let (_, execURL) = resolveAppBundleExecutableURL() {
        targetExecPath = execURL.path
    } else if let bundleExec = Bundle.main.executableURL?.resolvingSymlinksInPath().path {
        targetExecPath = bundleExec
    } else {
        targetExecPath = CommandLine.arguments.first ?? ""
    }

    if !targetExecPath.isEmpty && FileManager.default.isExecutableFile(atPath: targetExecPath) {
        var childEnv = env
        childEnv["DISK_HEALTH_DETACHED"] = "1"
        childEnv["DISK_HEALTH_REEXEC"] = "1"
        childEnv.removeValue(forKey: "TERM")
        childEnv.removeValue(forKey: "TERM_PROGRAM")
        childEnv.removeValue(forKey: "TERM_PROGRAM_VERSION")
        childEnv.removeValue(forKey: "TERM_SESSION_ID")

        if spawnDetachedSessionProcess(executablePath: targetExecPath, arguments: CommandLine.arguments, environment: childEnv) {
            _exit(0)
        }
    }

    _ = setsid()
    let devNull = open("/dev/null", O_RDWR)
    if devNull >= 0 {
        dup2(devNull, STDIN_FILENO)
        dup2(devNull, STDOUT_FILENO)
        dup2(devNull, STDERR_FILENO)
        if devNull > STDERR_FILENO {
            close(devNull)
        }
    }
}

func ensureRunningFromAppBundleIfAvailable() {
    let env = ProcessInfo.processInfo.environment
    guard env["DISK_HEALTH_REEXEC"] == nil else { return }
    guard let (_, execURL) = resolveAppBundleExecutableURL() else { return }

    let resolvedPath = execURL.path
    let rawArg0 = CommandLine.arguments.first ?? ""
    let arg0Standardized = URL(fileURLWithPath: rawArg0.hasPrefix("/") ? rawArg0 : "\(FileManager.default.currentDirectoryPath)/\(rawArg0)").standardizedFileURL.path
    let isInvokedViaSymlinkOrNonBundlePath = (arg0Standardized != resolvedPath)

    let isHeadless = isHeadlessCLIMode(args: CommandLine.arguments)
    let hasTTY = (isatty(STDIN_FILENO) == 1 || isatty(STDOUT_FILENO) == 1 || isatty(STDERR_FILENO) == 1)
    let hasTermEnv = (env["TERM_PROGRAM"] != nil || env["TERM"] != nil)

    // If launching GUI Menu Bar mode from a terminal or via the disk-health symlink,
    // immediately spawn a detached session process (POSIX_SPAWN_SETSID) and exit the parent.
    if !isHeadless && (hasTTY || hasTermEnv || isInvokedViaSymlinkOrNonBundlePath) &&
       (env["DISK_HEALTH_CONFIG_DIR"] == nil || env["DISK_HEALTH_FORCE_DETACH_TEST"] == "1") {
        var childEnv = env
        childEnv["DISK_HEALTH_DETACHED"] = "1"
        childEnv["DISK_HEALTH_REEXEC"] = "1"
        childEnv.removeValue(forKey: "TERM")
        childEnv.removeValue(forKey: "TERM_PROGRAM")
        childEnv.removeValue(forKey: "TERM_PROGRAM_VERSION")
        childEnv.removeValue(forKey: "TERM_SESSION_ID")

        if spawnDetachedSessionProcess(executablePath: resolvedPath, arguments: CommandLine.arguments, environment: childEnv) {
            _exit(0)
        }
    }

    if Bundle.main.bundleIdentifier == nil || isInvokedViaSymlinkOrNonBundlePath {
        setenv("DISK_HEALTH_REEXEC", "1", 1)
        var cArgs: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.enumerated().map { idx, arg in
            strdup(idx == 0 ? resolvedPath : arg)
        }
        cArgs.append(nil)
        execv(resolvedPath, &cArgs)
        for ptr in cArgs {
            if let ptr = ptr { free(ptr) }
        }
    }
}

ensureRunningFromAppBundleIfAvailable()
parseCommandLine()
