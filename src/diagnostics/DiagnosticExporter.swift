import Foundation

// MARK: - Diagnostic Exporter

final class DiagnosticExporter {
    static let shared = DiagnosticExporter()

    func generateDiagnosticReport(snapshot: DiskHealthSnapshot? = nil) -> [String: Any] {
        let snap = snapshot ?? DiskHealthMonitor.shared.evaluateHealth(forceCanary: true, allowNotifications: false)
        let cfg = ConfigManager.shared.currentConfig
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let hostName = ProcessInfo.processInfo.hostName

        let report: [String: Any] = [
            "reportVersion": "2.1.0",
            "timestamp": isoTimestampFormatter.string(from: Date()),
            "system": [
                "osVersion": osVersion,
                "hostName": hostName,
                "appVersion": "2.1.0 (Build 3)"
            ],
            "target": [
                "volumePath": cfg.targetVolumePath ?? "auto",
                "deviceQuery": cfg.targetDeviceQuery ?? "auto"
            ],
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
            ]
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
