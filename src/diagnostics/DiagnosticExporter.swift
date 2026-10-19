import Foundation

// MARK: - Diagnostic Exporter

final class DiagnosticExporter {
    static let shared = DiagnosticExporter()

    func generateDiagnosticReport(snapshot: DiskHealthSnapshot? = nil) -> [String: Any] {
        let snap = snapshot ?? DiskHealthMonitor.shared.evaluateHealth(forceCanary: true, allowNotifications: false)
        let cfg = ConfigManager.shared.currentConfig
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let hostName = ProcessInfo.processInfo.hostName

        // Enumerate all detected block storage devices for topology diagnostics
        var rawDevices = [DiskHardwareMetrics](repeating: DiskHardwareMetrics(), count: 32)
        let devCount = Int(DiskListAllDevices(&rawDevices, 32))
        var detectedDevicesList: [[String: Any]] = []
        for i in 0..<devCount {
            let d = rawDevices[i]
            let bsd = cStringToSwift(d.bsdName)
            var cMount = [CChar](repeating: 0, count: 512)
            let hasMount = !bsd.isEmpty && DiskFindMountForBlockDevice(bsd, &cMount, 512)
            let mountPath = hasMount ? String(cString: cMount) : ""
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
            let sanitized = (!token.isEmpty)
                ? logContent.replacingOccurrences(of: token, with: "[REDACTED_TOKEN]")
                : logContent
            let allLines = sanitized.components(separatedBy: .newlines).filter { !$0.isEmpty }
            recentLogLines = Array(allLines.suffix(100))
        }

        let report: [String: Any] = [
            "reportVersion": "2.1.0",
            "timestamp": isoTimestampFormatter.string(from: Date()),
            "system": [
                "osVersion": osVersion,
                "hostName": hostName,
                "appVersion": "\(kAppVersion) (Build \(kAppBuildNumber))",
                "architecture": kAppArchShort
            ],
            "target": [
                "volumePath": cfg.targetVolumePath ?? "auto",
                "deviceQuery": cfg.targetDeviceQuery ?? "auto"
            ],
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
                "usedPercent": snap.usedPercent,
                "lastVerifyResult": snap.lastVerifyResult
            ],
            "smart": [
                "valid": snap.smartValid,
                "temperatureCelsius": snap.temperatureCelsius,
                "peakTemperatureCelsius": snap.peakTemperatureCelsius,
                "lifeRemainingPercent": snap.lifeRemainingPercent,
                "percentageUsed": snap.percentageUsed,
                "availableSpare": snap.availableSpare,
                "availableSpareThreshold": snap.availableSpareThreshold,
                "totalTerabytesWritten": snap.totalTerabytesWritten,
                "totalTerabytesRead": snap.totalTerabytesRead,
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
                "telegramChatId": cfg.telegramChatId.isEmpty ? "None" : cfg.telegramChatId
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
            do {
                try data.write(to: URL(fileURLWithPath: targetPath), options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetPath)
                return targetPath
            } catch {
                ConfigManager.shared.log("Failed to write diagnostic report: \(error.localizedDescription)")
                return nil
            }
        }
        return nil
    }
}
