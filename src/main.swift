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
      --watch-mounts        Run a check triggered by a mount event
      --deep                Include filesystem verification (diskutil verifyVolume)
      --list-disks          List all detected block storage devices, buses, and SMART status
      --json                Dump current telemetry snapshot as pretty-printed JSON
      --export-config       Export current configuration as sanitized JSON (--unmasked for secrets)
      --import-config <file> Import and apply configuration profile from a JSON file
      --export-diagnostics  Generate comprehensive JSON diagnostic report in logs/ (or [path])
      --export-html         Generate standalone HTML health & RMA report in logs/ (or [path])
      --surface-scan        Run non-destructive physical media read validation (F_NOCACHE)
      --verify              Run volume filesystem verification (diskutil verifyVolume)
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

    // Process override flags first (in-memory overrides for this invocation)
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

    if args.contains("--surface-scan") {
        let res = DiskHealthMonitor.shared.runSurfaceReadScan()
        print("Surface Read Validation: \(res.summary)")
        exit(res.ok ? 0 : 2)
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
        let snap = DiskHealthMonitor.shared.evaluateHealth(forceCanary: true, allowNotifications: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(snap), let str = String(data: data, encoding: .utf8) {
            print(str)
        }
        exit(Int32(snap.overallSeverity.rank))
    }

    let isCheckMode = args.contains("--cli") || args.contains("--status") || args.contains("--check") || args.contains("--watch-mounts") || args.contains("--deep")
    if isCheckMode {
        let notify = args.contains("--notify") || args.contains("--notify-if-unhealthy") || args.contains("--check") || args.contains("--watch-mounts")
        if args.contains("--deep") {
            let sem = DispatchSemaphore(value: 0)
            DiskHealthMonitor.shared.runVolumeVerification(sendTelegram: notify) { _, _ in
                sem.signal()
            }
            sem.wait()
        }
        let snap = DiskHealthMonitor.shared.evaluateHealth(forceCanary: true, allowNotifications: notify)

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
        exit(Int32(snap.overallSeverity.rank))
    }

    if args.contains("--send-report") {
        let snap = DiskHealthMonitor.shared.evaluateHealth(forceCanary: true, allowNotifications: false)
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
        "--surface-scan", "--list-disks", "--json",
        "--cli", "--status", "--check", "--watch-mounts", "--deep",
        "--send-report", "--verify", "--verify-volume", "--verify-apfs"
    ]
    for arg in args.dropFirst() {
        if cliFlags.contains(arg) {
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
