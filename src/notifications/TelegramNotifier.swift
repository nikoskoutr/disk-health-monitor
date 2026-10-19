import Foundation

// MARK: - Telegram Notifier

final class TelegramNotifier {
    static let shared = TelegramNotifier()
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12.0
        config.timeoutIntervalForResource = 15.0
        config.connectionProxyDictionary = [:]
        self.session = URLSession(configuration: config)
    }

    func sendMessageAsync(htmlText: String, disableNotification: Bool = false, completion: ((Bool) -> Void)? = nil) {
        let token = ConfigManager.shared.resolvedTelegramBotToken
        let chatId = ConfigManager.shared.resolvedTelegramChatId
        guard !token.isEmpty, !chatId.isEmpty,
              let url = URL(string: "https://api.telegram.org/bot\(token)/sendMessage") else {
            completion?(false)
            return
        }

        let payload: [String: Any] = [
            "chat_id": chatId,
            "text": htmlText,
            "parse_mode": "HTML",
            "disable_notification": disableNotification
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            completion?(false)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                ConfigManager.shared.log("Telegram send error: \(error.localizedDescription)")
                completion?(false)
                return
            }
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ok = json["ok"] as? Bool, ok {
                ConfigManager.shared.log("Telegram notification sent successfully.")
                completion?(true)
            } else {
                let respStr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "unknown"
                ConfigManager.shared.log("Telegram API response: \(respStr)")
                completion?(false)
            }
        }
        task.resume()
    }

    @discardableResult
    func sendMessage(htmlText: String, disableNotification: Bool = false) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var success = false
        sendMessageAsync(htmlText: htmlText, disableNotification: disableNotification) { ok in
            success = ok
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 15.0)
        return success
    }

    func sendTestMessage(token: String, chatId: String, completion: @escaping (Bool, String) -> Void) {
        guard !token.isEmpty else {
            completion(false, "Bot token cannot be empty.")
            return
        }
        guard !chatId.isEmpty else {
            completion(false, "Chat ID cannot be empty.")
            return
        }
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/sendMessage") else {
            completion(false, "Invalid Telegram API URL.")
            return
        }

        let payload: [String: Any] = [
            "chat_id": chatId,
            "text": "🔔 <b>Disk Health Monitor Test Alert</b>\n\nTelegram notification connection is working properly!",
            "parse_mode": "HTML"
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            completion(false, "Failed to serialize test payload.")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(false, error.localizedDescription)
                return
            }
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ok = json["ok"] as? Bool, ok {
                completion(true, "Test message delivered successfully!")
            } else {
                let desc: String
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errDesc = json["description"] as? String {
                    desc = errDesc
                } else {
                    desc = data.flatMap { String(data: $0, encoding: .utf8) } ?? "Unknown Telegram error"
                }
                completion(false, desc)
            }
        }
        task.resume()
    }

    func escapeHTML(_ raw: String) -> String {
        return raw
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    func formatReportHTML(snapshot: DiskHealthSnapshot, title: String) -> String {
        let statusLine = "\(snapshot.overallSeverity.emoji) <b>\(escapeHTML(title))</b>"
        let mountState = snapshot.isMounted
            ? "✅ Mounted (<code>\(escapeHTML(snapshot.mountPoint))</code>, \(snapshot.isReadOnly ? "⚠️ READ-ONLY" : "R/W"))"
            : "❌ <b>UNMOUNTED / OFFLINE</b>"
        let capacityLine = snapshot.isMounted
            ? String(format: "%@ used / %@ free (%.1f%% of %@)",
                     formatBytes(snapshot.usedBytes),
                     formatBytes(snapshot.freeBytes),
                     snapshot.usedPercent,
                     formatBytes(snapshot.totalBytes))
            : "N/A"
        let smartTemp = snapshot.smartValid ? "\(snapshot.temperatureCelsius)°C (Peak: \(snapshot.peakTemperatureCelsius)°C)" : "N/A"
        let smartLife = snapshot.smartValid ? "\(snapshot.lifeRemainingPercent)% remaining (Spare: \(snapshot.availableSpare)%)" : "N/A"
        let smartTbw = snapshot.smartValid ? String(format: "%.2f TBW / %.2f TB Read", snapshot.totalTerabytesWritten, snapshot.totalTerabytesRead) : "N/A"
        let smartCounters = snapshot.smartValid
            ? "POH: \(snapshot.powerOnHours)h | Cycles: \(snapshot.powerCycles) | Unsafe: \(snapshot.unsafeShutdowns) | Media Err: \(snapshot.mediaErrors)"
            : "N/A"
        let canaryStr = snapshot.canaryOk ? String(format: "✅ OK (%.2f ms)", snapshot.canaryLatencyMs) : "❌ FAILED (\(escapeHTML(snapshot.canaryError)))"

        var lines: [String] = [
            statusLine,
            "━━━━━━━━━━━━━━━━━━━━",
            "• <b>Status:</b> \(snapshot.overallSeverity.rawValue) (Score: \(snapshot.healthScore)/100)",
            "• <b>Device:</b> \(escapeHTML(snapshot.vendorName)) \(escapeHTML(snapshot.productName)) (<code>\(escapeHTML(snapshot.bsdName.isEmpty ? "offline" : snapshot.bsdName))</code>)",
            "• <b>Bus / Link:</b> \(escapeHTML(snapshot.interconnectType)) • \(escapeHTML(snapshot.linkSpeedFormatted))",
            "• <b>Serial:</b> <code>\(escapeHTML(snapshot.serialNumber.isEmpty ? "N/A" : snapshot.serialNumber))</code>",
            "• <b>Volume:</b> \(mountState)",
            "• <b>Capacity:</b> \(capacityLine)",
            "• <b>Temperature:</b> \(smartTemp)",
            "• <b>SSD Wear / Spare:</b> \(smartLife)",
            "• <b>Lifetime I/O:</b> \(smartTbw)",
            "• <b>SMART Counters:</b> \(smartCounters)",
            "• <b>Driver I/O Errors:</b> \(snapshot.errorsRead) R / \(snapshot.errorsWritten) W (Retries: \(snapshot.retriesRead) R / \(snapshot.retriesWritten) W)",
            "• <b>I/O Canary Probe:</b> \(canaryStr)",
            "• <b>File System Check:</b> \(escapeHTML(snapshot.lastVerifyResult))"
        ]

        if !snapshot.issues.isEmpty {
            lines.append("")
            lines.append("⚠️ <b>Active Health Findings:</b>")
            for issue in snapshot.issues {
                lines.append("  \(issue.severity.emoji) <b>\(escapeHTML(issue.title)):</b> \(escapeHTML(issue.detail))")
            }
        }

        return lines.joined(separator: "\n")
    }
}
