import Foundation
import AppKit
import SwiftUI

// MARK: - CLI Argument Processing & Entry Point

func printUsage() {
    print("""
    Universal macOS Disk Health Monitor & Telemetry Agent
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
      --verify              Run volume filesystem verification (diskutil verifyVolume)
      --send-report         Dispatch on-demand HTML health report to Telegram
      --menubar             Launch the macOS Menu Bar status item application (default)
      --help, -h            Show this help manual

    Target Overrides:
      --volume <path>       Specify target mount path to monitor (e.g., /Volumes/MyDrive or /)
      --device <query>      Specify target device BSD name (e.g., disk4), product name, or serial
      --notify              When used with --status or --verify, dispatch alerts if unhealthy

    Configuration & Environment:
      Configuration files:  ~/.config/disk-health-monitor/config.json
      Logs directory:       logs/ (or ~/.config/disk-health-monitor/logs)
      Environment variables: DISK_HEALTH_VOLUME, DISK_HEALTH_DEVICE, TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID
    """)
}

func parseCommandLine() {
    let args = CommandLine.arguments

    // Process override flags first (in-memory overrides for this invocation)
    for i in 0..<args.count {
        if args[i] == "--volume" && i + 1 < args.count {
            ConfigManager.shared.overrideTarget(volumePath: args[i + 1], deviceQuery: nil)
        } else if args[i] == "--device" && i + 1 < args.count {
            ConfigManager.shared.overrideTarget(volumePath: nil, deviceQuery: args[i + 1])
        }
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
        print("  \(snap.overallSeverity.emoji) DISK HEALTH MONITOR — \(snap.overallSeverity.rawValue) (Score: \(snap.healthScore)/100)")
        print("============================================================")
        print("  Device         : \(snap.vendorName) \(snap.productName) (\(snap.bsdName.isEmpty ? "offline" : snap.bsdName))")
        print("  Interconnect   : \(snap.interconnectType) (\(snap.isInternal ? "Internal" : "External")) • \(snap.linkSpeedFormatted)")
        print("  Serial Number  : \(snap.serialNumber.isEmpty ? "N/A" : snap.serialNumber)")
        print("  Mount Status   : \(snap.isMounted ? "Mounted at \(snap.mountPoint) (\(snap.isReadOnly ? "READ-ONLY" : "R/W")) [\(snap.filesystemType)]" : "UNMOUNTED")")
        if snap.isMounted {
            print(String(format: "  Capacity       : %@ used / %@ free (%.1f%% of %@)",
                         formatBytes(snap.usedBytes), formatBytes(snap.freeBytes), snap.usedPercent, formatBytes(snap.totalBytes)))
        }
        if snap.smartValid {
            print("  Temperature    : \(snap.temperatureCelsius)°C (Peak: \(snap.peakTemperatureCelsius)°C | Warn: \(ConfigManager.shared.config.tempWarningCelsius)°C | Crit: \(ConfigManager.shared.config.tempCriticalCelsius)°C)")
            print("  SSD Lifespan   : \(snap.lifeRemainingPercent)% Remaining (Percentage Used: \(snap.percentageUsed)%, Spare: \(snap.availableSpare)% / Thresh: \(snap.availableSpareThreshold)%)")
            print(String(format: "  Lifetime I/O   : %.2f TB Written (TBW) / %.2f TB Read", snap.totalTerabytesWritten, snap.totalTerabytesRead))
            print("  SMART Counters : Power On: \(snap.powerOnHours)h (\(snap.powerOnHours / 24)d) | Cycles: \(snap.powerCycles) | Unsafe Shutdowns: \(snap.unsafeShutdowns)")
            print("  SMART Errors   : Critical Warning: 0x\(String(format: "%02X", snap.criticalWarning)) | Media Errors: \(snap.mediaErrors) | Error Log: \(snap.errorInfoLogEntries)")
        }
        if snap.statsValid {
            print(String(format: "  Driver Stats   : Errors: %llu R / %llu W | Retries: %llu R / %llu W | Avg Latency: %.2f ms R / %.2f ms W",
                         snap.errorsRead, snap.errorsWritten, snap.retriesRead, snap.retriesWritten, snap.avgReadLatencyMs, snap.avgWriteLatencyMs))
        }
        if ConfigManager.shared.config.enableActiveCanary {
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
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}

parseCommandLine()
