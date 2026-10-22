import Foundation

// MARK: - Diagnostic Exporter

final class DiagnosticExporter: @unchecked Sendable {
    static let shared = DiagnosticExporter()

    func generateDiagnosticReport(snapshot: DiskHealthSnapshot? = nil) -> [String: Any] {
        let snap = snapshot ?? DiskHealthMonitor.shared.evaluateHealth(forceCanary: true, allowNotifications: false)
        let cfg = ConfigManager.shared.currentConfig
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let hostName = ProcessInfo.processInfo.hostName

        // Enumerate all detected block storage devices for topology diagnostics
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

        // Capture up to the last 100 lines of health.log
        var recentLogLines: [String] = []
        if let logContent = try? String(contentsOfFile: ConfigManager.shared.logFilePath, encoding: .utf8) {
            let token = ConfigManager.shared.resolvedTelegramBotToken
            let webhook = ConfigManager.shared.resolvedWebhookUrl
            let sanitizedToken = TelegramNotifier.redactToken(logContent, token: token)
            let sanitized = WebhookNotifier.redactWebhookUrl(sanitizedToken, webhookUrl: webhook)
            let allLines = sanitized.components(separatedBy: .newlines).filter { !$0.isEmpty }
            recentLogLines = Array(allLines.suffix(100))
        }

        let report: [String: Any] = [
            "reportVersion": kAppVersion,
            "timestamp": isoTimestampFormatter.string(from: Date()),
            "system": [
                "osVersion": osVersion,
                "hostName": hostName,
                "appVersion": "\(kAppVersion) (Build \(kAppBuildNumber))",
                "architecture": kAppArchShort
            ],
            "target": [
                "volumePath": cfg.targetVolumePath ?? "auto",
                "deviceQuery": cfg.targetDeviceQuery ?? "auto",
                "monitorAllDisks": cfg.monitorAllDisks,
                "monitoredTargets": cfg.monitoredTargets
            ],
            "monitoredFleet": (DiskHealthMonitor.shared.currentMultiSnapshot?.disks ?? [snap]).map { d in
                [
                    "driveKey": d.driveKey,
                    "bsdName": d.bsdName,
                    "vendorName": d.vendorName,
                    "productName": d.productName,
                    "serialNumber": d.serialNumber,
                    "mountPoint": d.mountPoint,
                    "overallSeverity": d.overallSeverity.rawValue,
                    "healthScore": d.healthScore,
                    "temperatureCelsius": d.temperatureCelsius,
                    "lifeRemainingPercent": d.lifeRemainingPercent,
                    "totalTerabytesWritten": d.totalTerabytesWritten,
                    "issuesCount": d.issues.count
                ]
            },
            "detectedDevices": detectedDevicesList,
            "hardware": [
                "productName": snap.productName,
                "vendorName": snap.vendorName,
                "bsdName": snap.bsdName,
                "interconnectType": snap.interconnectType,
                "isInternal": snap.isInternal,
                "serialNumber": snap.serialNumber,
                "linkSpeedBps": snap.linkSpeedBps,
                "linkSpeedFormatted": snap.linkSpeedFormatted
            ],
            "filesystem": [
                "isMounted": snap.isMounted,
                "mountPoint": snap.mountPoint,
                "filesystemType": snap.filesystemType,
                "isReadOnly": snap.isReadOnly,
                "totalBytes": snap.totalBytes,
                "usedBytes": snap.usedBytes,
                "freeBytes": snap.freeBytes,
                "purgeableBytes": snap.purgeableBytes,
                "usedPercent": snap.usedPercent,
                "lastVerifyResult": snap.lastVerifyResult
            ],
            "smart": [
                "valid": snap.smartValid,
                "temperatureCelsius": snap.temperatureCelsius,
                "temperatureKelvin": snap.temperatureKelvin,
                "peakTemperatureCelsius": snap.peakTemperatureCelsius,
                "lifeRemainingPercent": snap.lifeRemainingPercent,
                "percentageUsed": snap.percentageUsed,
                "availableSpare": snap.availableSpare,
                "availableSpareThreshold": snap.availableSpareThreshold,
                "dataUnitsWritten": snap.dataUnitsWritten,
                "dataUnitsRead": snap.dataUnitsRead,
                "totalTerabytesWritten": snap.totalTerabytesWritten,
                "totalTerabytesRead": snap.totalTerabytesRead,
                "dailyTerabytesWritten": snap.dailyTerabytesWritten,
                "estimatedRemainingLife": snap.estimatedRemainingLifeFormatted,
                "hostReadCommands": snap.hostReadCommands,
                "hostWriteCommands": snap.hostWriteCommands,
                "controllerBusyTime": snap.controllerBusyTime,
                "powerOnHours": snap.powerOnHours,
                "powerCycles": snap.powerCycles,
                "unsafeShutdowns": snap.unsafeShutdowns,
                "mediaErrors": snap.mediaErrors,
                "errorInfoLogEntries": snap.errorInfoLogEntries,
                "criticalWarning": snap.criticalWarning
            ],
            "driverStats": [
                "valid": snap.statsValid,
                "sessionBytesRead": snap.sessionBytesRead,
                "sessionBytesWritten": snap.sessionBytesWritten,
                "errorsRead": snap.errorsRead,
                "errorsWritten": snap.errorsWritten,
                "retriesRead": snap.retriesRead,
                "retriesWritten": snap.retriesWritten,
                "avgReadLatencyMs": snap.avgReadLatencyMs,
                "avgWriteLatencyMs": snap.avgWriteLatencyMs,
                "readThroughputMBps": snap.readThroughputMBps,
                "writeThroughputMBps": snap.writeThroughputMBps
            ],
            "canary": [
                "ok": snap.canaryOk,
                "latencyMs": snap.canaryLatencyMs,
                "error": snap.canaryError
            ],
            "evaluation": [
                "overallSeverity": snap.overallSeverity.rawValue,
                "healthScore": snap.healthScore,
                "issues": snap.issues.map { [
                    "code": $0.code,
                    "title": $0.title,
                    "detail": $0.detail,
                    "severity": $0.severity.rawValue
                ]}
            ],
            "configuration": [
                "pollIntervalSeconds": cfg.pollIntervalSeconds,
                "alertCooldownSeconds": cfg.alertCooldownSeconds,
                "tempWarningCelsius": cfg.tempWarningCelsius,
                "tempCriticalCelsius": cfg.tempCriticalCelsius,
                "diskUsedWarningPercent": cfg.diskUsedWarningPercent,
                "diskUsedCriticalPercent": cfg.diskUsedCriticalPercent,
                "minFreeSpaceWarningGB": cfg.minFreeSpaceWarningGB,
                "minFreeSpaceCriticalGB": cfg.minFreeSpaceCriticalGB,
                "minExpectedUsbSpeedBps": cfg.minExpectedUsbSpeedBps,
                "enableActiveCanary": cfg.enableActiveCanary,
                "enableNativeNotifications": cfg.enableNativeNotifications,
                "telegramBotToken": ConfigManager.shared.resolvedTelegramBotToken.isEmpty ? "None" : "•••••••• (Protected)",
                "telegramChatId": ConfigManager.shared.resolvedTelegramChatId.isEmpty ? "None" : ConfigManager.shared.resolvedTelegramChatId,
                "webhookUrl": ConfigManager.shared.resolvedWebhookUrl.isEmpty ? "None" : "•••••••• (Protected)",
                "alertScriptPath": ConfigManager.shared.resolvedAlertScriptPath.isEmpty ? "None" : ConfigManager.shared.resolvedAlertScriptPath
            ],
            "recentLogLines": recentLogLines
        ]
        return report
    }

    func exportDiagnosticReportJSON(snapshot: DiskHealthSnapshot? = nil) -> String {
        let rep = generateDiagnosticReport(snapshot: snapshot)
        if JSONSerialization.isValidJSONObject(rep),
           let data = try? JSONSerialization.data(withJSONObject: rep, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }

    func saveDiagnosticReportToFile(at path: String? = nil, snapshot: DiskHealthSnapshot? = nil) -> String? {
        let jsonStr = exportDiagnosticReportJSON(snapshot: snapshot)
        let targetPath: String
        if let p = path, !p.isEmpty {
            targetPath = (p as NSString).standardizingPath
        } else {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "yyyyMMdd-HHmmss"
            let stamp = df.string(from: Date())
            targetPath = "\(ConfigManager.shared.logsDir)/diagnostic_report_\(stamp).json"
        }

        if let data = jsonStr.data(using: .utf8) {
            if AtomicFileWriter.writeRestricted(data: data, toPath: targetPath, permissions: 0o600) {
                return targetPath
            } else {
                ConfigManager.shared.log("Failed to write diagnostic report: could not write to \(targetPath)")
                return nil
            }
        }
        return nil
    }

    func exportDiagnosticReportHTML(snapshot: DiskHealthSnapshot? = nil) -> String {
        let snap = snapshot ?? DiskHealthMonitor.shared.evaluateHealth(forceCanary: true, allowNotifications: false)
        let multi = DiskHealthMonitor.shared.currentMultiSnapshot ?? DiskHealthMonitor.shared.evaluateAllMonitoredDisks(forceCanary: true, allowNotifications: false)
        let esc = TelegramNotifier.shared.escapeHTML
        let badgeColor: String = {
            switch snap.overallSeverity {
            case .healthy: return "#10b981"
            case .warning: return "#f59e0b"
            case .critical: return "#ef4444"
            }
        }()

        var fleetSection = ""
        if multi.disks.count > 1 {
            var fleetRows = ""
            for d in multi.disks {
                let statusColor = d.overallSeverity == .healthy ? "#10b981" : (d.overallSeverity == .warning ? "#f59e0b" : "#ef4444")
                fleetRows += """
                <tr>
                  <td><b>\(esc(d.vendorName)) \(esc(d.productName))</b></td>
                  <td><code>\(esc(d.bsdName))</code></td>
                  <td><code>\(esc(d.mountPoint.isEmpty ? "Unmounted" : d.mountPoint))</code></td>
                  <td>\(d.smartValid ? "\(d.temperatureCelsius)°C" : "N/A")</td>
                  <td>\(d.smartValid ? "\(d.lifeRemainingPercent)% Left" : "N/A")</td>
                  <td>\(d.smartValid ? String(format: "%.2f TBW", d.totalTerabytesWritten) : "N/A")</td>
                  <td><span style='color:\(statusColor);font-weight:700;'>\(esc(d.overallSeverity.rawValue)) (\(d.healthScore)%)</span></td>
                </tr>
                """
            }
            fleetSection = """
            <div class="card">
              <h2>Multi-Disk Monitored Fleet Overview (\(multi.disks.count) Devices)</h2>
              <table>
                <thead>
                  <tr style='border-bottom: 2px solid #475569;'>
                    <th style='width:auto;'>Device</th><th style='width:auto;'>BSD</th><th style='width:auto;'>Mount</th><th style='width:auto;'>Temp</th><th style='width:auto;'>Wear</th><th style='width:auto;'>TBW</th><th style='width:auto;'>Status</th>
                  </tr>
                </thead>
                <tbody>
                  \(fleetRows)
                </tbody>
              </table>
            </div>
            """
        }

        var issuesRows = ""
        if snap.issues.isEmpty {
            issuesRows = "<tr><td colspan='3' style='color:#10b981;font-weight:600;'>✅ All 12 hardware, thermal, and filesystem health checks passed.</td></tr>"
        } else {
            for issue in snap.issues {
                issuesRows += "<tr><td><b>\(esc(issue.severity.rawValue))</b></td><td><code>\(esc(issue.code))</code></td><td><b>\(esc(issue.title))</b>: \(esc(issue.detail))</td></tr>"
            }
        }

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="UTF-8">
        <title>Disk Health &amp; RMA Report — \(esc(snap.vendorName)) \(esc(snap.productName))</title>
        <style>
          body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #0f172a; color: #e2e8f0; margin: 24px; }
          .card { background: #1e293b; border: 1px solid #334155; border-radius: 12px; padding: 20px; margin-bottom: 18px; }
          h1, h2 { margin-top: 0; color: #f8fafc; }
          .badge { display: inline-block; padding: 6px 14px; border-radius: 999px; font-weight: 700; background: \(badgeColor); color: #fff; }
          table { width: 100%; border-collapse: collapse; margin-top: 8px; }
          th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid #334155; font-size: 13px; }
          th { color: #94a3b8; width: 32%; }
          code { background: #0f172a; padding: 2px 6px; border-radius: 4px; color: #38bdf8; }
          @media print { body { background: #fff; color: #111; } .card { background: #fff; border-color: #ccc; } th { color: #444; } }
        </style>
        </head>
        <body>
          <div class="card">
            <h1>Universal Disk Health &amp; RMA Report</h1>
            <p>Generated: <code>\(esc(snap.formattedTime))</code> • Architecture: <code>\(esc(kAppArchitecture))</code> • Version: <code>v\(esc(kAppVersion))</code></p>
            <span class="badge">\(esc(snap.overallSeverity.rawValue)) — Score: \(snap.healthScore)/100</span>
          </div>
          \(fleetSection)
          <div class="card">
            <h2>1. Hardware &amp; Interconnect Identity</h2>
            <table>
              <tr><th>Device Model</th><td>\(esc(snap.vendorName)) \(esc(snap.productName)) (Rev: \(esc(snap.productRevision.isEmpty ? "N/A" : snap.productRevision)))</td></tr>
              <tr><th>Serial Number</th><td><code>\(esc(snap.serialNumber.isEmpty ? "N/A" : snap.serialNumber))</code></td></tr>
              <tr><th>BSD Identifier &amp; Bus</th><td><code>\(esc(snap.bsdName.isEmpty ? "offline" : snap.bsdName))</code> • \(esc(snap.interconnectType)) (\(esc(snap.linkSpeedFormatted)))</td></tr>
              <tr><th>Volume Mount &amp; Capacity</th><td>\(snap.isMounted ? "<code>\(esc(snap.mountPoint))</code> (\(esc(snap.filesystemType)), \(snap.isReadOnly ? "Read-Only" : "R/W")) — \(formatBytes(snap.usedBytes)) used / \(formatBytes(snap.freeBytes)) available (Purgeable: \(formatBytes(snap.purgeableBytes)))" : "UNMOUNTED")</td></tr>
            </table>
          </div>
          <div class="card">
            <h2>2. NVMe S.M.A.R.T. &amp; Kernel Driver Telemetry</h2>
            <table>
              <tr><th>Temperature</th><td>\(snap.smartValid ? "\(snap.temperatureCelsius)°C (Peak: \(snap.peakTemperatureCelsius)°C)" : "N/A")</td></tr>
              <tr><th>SSD Wear &amp; Available Spare</th><td>\(snap.smartValid ? "\(snap.lifeRemainingPercent)% Life Remaining (Used: \(snap.percentageUsed)%, Available Spare: \(snap.availableSpare)% / Thresh: \(snap.availableSpareThreshold)%)" : "N/A")</td></tr>
              <tr><th>Lifetime Data Read / Written</th><td>\(snap.smartValid ? String(format: "%.2f TB Written (TBW) / %.2f TB Read", snap.totalTerabytesWritten, snap.totalTerabytesRead) : "N/A")</td></tr>
              <tr><th>Power Cycles / Hours / Unsafe</th><td>\(snap.smartValid ? "Cycles: \(snap.powerCycles) • POH: \(snap.powerOnHours)h • Unsafe Shutdowns: \(snap.unsafeShutdowns)" : "N/A")</td></tr>
              <tr><th>Media &amp; Driver I/O Errors</th><td>Media Errors: \(snap.mediaErrors) • Driver Errors: \(snap.errorsRead) R / \(snap.errorsWritten) W • Retries: \(snap.retriesRead) R / \(snap.retriesWritten) W</td></tr>
              <tr><th>Active Canary &amp; FS Verification</th><td>Canary: \(snap.canaryOk ? String(format: "PASSED (%.2f ms)", snap.canaryLatencyMs) : "FAILED (\(esc(snap.canaryError)))") • Verify: \(esc(snap.lastVerifyResult))</td></tr>
            </table>
          </div>
          <div class="card">
            <h2>3. Active Health Findings</h2>
            <table>
              <tr><th>Severity</th><th>Rule Code</th><th>Description</th></tr>
              \(issuesRows)
            </table>
          </div>
        </body>
        </html>
        """
    }

    func saveDiagnosticReportHTMLToFile(at path: String? = nil, snapshot: DiskHealthSnapshot? = nil) -> String? {
        let htmlStr = exportDiagnosticReportHTML(snapshot: snapshot)
        let targetPath: String
        if let p = path, !p.isEmpty {
            targetPath = (p as NSString).standardizingPath
        } else {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "yyyyMMdd-HHmmss"
            let stamp = df.string(from: Date())
            targetPath = "\(ConfigManager.shared.logsDir)/health_report_\(stamp).html"
        }
        if let data = htmlStr.data(using: .utf8) {
            if AtomicFileWriter.writeRestricted(data: data, toPath: targetPath, permissions: 0o600) {
                return targetPath
            } else {
                ConfigManager.shared.log("Failed to write HTML health report: could not write to \(targetPath)")
                return nil
            }
        }
        return nil
    }
}
