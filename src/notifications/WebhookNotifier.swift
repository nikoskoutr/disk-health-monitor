// ============================================================================
// File: WebhookNotifier.swift
// Module: Layer 3 (Telemetry & Domain Engine / Notifications)
// Purpose: Universal multi-platform webhook dispatcher supporting Discord, Slack,
//          Home Assistant, and generic JSON endpoints with URL redaction.
// Concurrency: Thread-safe singleton using asynchronous URLSession tasks.
// ============================================================================

import Foundation

// MARK: - Universal Multi-Platform Webhook Notifier (Discord, Slack, Home Assistant, Generic JSON)

/// Asynchronous notification adapter dispatching webhook payloads across multiple services.
final class WebhookNotifier {
    static let shared = WebhookNotifier()
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12.0
        config.timeoutIntervalForResource = 15.0
        self.session = URLSession(configuration: config)
    }

    static func redactWebhookUrl(_ text: String, webhookUrl: String) -> String {
        guard !webhookUrl.isEmpty else { return text }
        var result = text.replacingOccurrences(of: webhookUrl, with: "[REDACTED_WEBHOOK_URL]")
        if let url = URL(string: webhookUrl) {
            if !url.path.isEmpty && url.path != "/" {
                result = result.replacingOccurrences(of: url.path, with: "/[REDACTED_WEBHOOK_PATH]")
            }
            if let query = url.query, !query.isEmpty {
                result = result.replacingOccurrences(of: query, with: "[REDACTED_QUERY]")
            }
        }
        return result
    }

    static func buildPayload(snapshot: DiskHealthSnapshot, title: String, eventType: String) -> [String: Any] {
        let issueSummaries = snapshot.issues.map { "\($0.severity.emoji) [\($0.code)] \($0.title): \($0.detail)" }
        let issuesText = issueSummaries.isEmpty ? "All storage and filesystem health checks passed." : issueSummaries.joined(separator: "\n")
        let markdownSummary = """
        \(snapshot.overallSeverity.emoji) **\(title)**
        • **Status:** \(snapshot.overallSeverity.rawValue) (Score: \(snapshot.healthScore)/100)
        • **Device:** \(snapshot.vendorName) \(snapshot.productName) (`\(snapshot.bsdName.isEmpty ? "offline" : snapshot.bsdName)`)
        • **Bus / Link:** \(snapshot.interconnectType) • \(snapshot.linkSpeedFormatted)
        • **Volume:** \(snapshot.isMounted ? snapshot.mountPoint : "UNMOUNTED")
        • **Temperature:** \(snapshot.smartValid ? "\(snapshot.temperatureCelsius)°C (Peak: \(snapshot.peakTemperatureCelsius)°C)" : "N/A")
        • **Findings:**
        \(issuesText)
        """

        let trimmedSummary: String
        if markdownSummary.count > 1900 {
            trimmedSummary = String(markdownSummary.prefix(1900)) + "\n... [truncated]"
        } else {
            trimmedSummary = markdownSummary
        }

        return [
            "content": trimmedSummary, // Discord / Mattermost compatibility
            "text": trimmedSummary,    // Slack compatibility
            "message": trimmedSummary, // ntfy compatibility
            "event": eventType,
            "title": title,
            "timestamp": snapshot.formattedTime,
            "overallSeverity": snapshot.overallSeverity.rawValue,
            "healthScore": snapshot.healthScore,
            "device": [
                "vendorName": snapshot.vendorName,
                "productName": snapshot.productName,
                "bsdName": snapshot.bsdName,
                "serialNumber": snapshot.serialNumber,
                "interconnectType": snapshot.interconnectType,
                "linkSpeedFormatted": snapshot.linkSpeedFormatted
            ],
            "filesystem": [
                "isMounted": snapshot.isMounted,
                "mountPoint": snapshot.mountPoint,
                "freeBytes": snapshot.freeBytes,
                "purgeableBytes": snapshot.purgeableBytes,
                "totalBytes": snapshot.totalBytes,
                "usedPercent": snapshot.usedPercent
            ],
            "smart": [
                "valid": snapshot.smartValid,
                "temperatureCelsius": snapshot.temperatureCelsius,
                "lifeRemainingPercent": snapshot.lifeRemainingPercent,
                "availableSpare": snapshot.availableSpare,
                "mediaErrors": snapshot.mediaErrors,
                "unsafeShutdowns": snapshot.unsafeShutdowns
            ],
            "issues": snapshot.issues.map { [
                "code": $0.code,
                "severity": $0.severity.rawValue,
                "title": $0.title,
                "detail": $0.detail
            ] }
        ]
    }

    func sendWebhookAsync(snapshot: DiskHealthSnapshot, title: String, eventType: String = "health_alert", completion: ((Bool) -> Void)? = nil) {
        let webhookUrlStr = ConfigManager.shared.resolvedWebhookUrl
        guard !webhookUrlStr.isEmpty,
              let url = URL(string: webhookUrlStr),
              let scheme = url.scheme?.lowercased(),
              (scheme == "https" || scheme == "http") else {
            completion?(false)
            return
        }

        let payload = WebhookNotifier.buildPayload(snapshot: snapshot, title: title, eventType: eventType)
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
                let safeErr = WebhookNotifier.redactWebhookUrl(error.localizedDescription, webhookUrl: webhookUrlStr)
                ConfigManager.shared.log("Webhook send error: \(safeErr)")
                completion?(false)
                return
            }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(statusCode) {
                ConfigManager.shared.log("Webhook notification sent successfully (HTTP \(statusCode)).")
                completion?(true)
            } else {
                let rawResp = data.flatMap { String(data: $0, encoding: .utf8) } ?? "HTTP \(statusCode)"
                let safeResp = WebhookNotifier.redactWebhookUrl(rawResp, webhookUrl: webhookUrlStr)
                ConfigManager.shared.log("Webhook HTTP error (\(statusCode)): \(safeResp)")
                completion?(false)
            }
        }
        task.resume()
    }

    func sendTestWebhook(webhookUrl: String, completion: @escaping (Bool, String) -> Void) {
        let trimmed = webhookUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              (scheme == "https" || scheme == "http") else {
            completion(false, "Please enter a valid HTTP/HTTPS Webhook URL.")
            return
        }

        let snap = DiskHealthMonitor.shared.currentSnapshot ?? DiskHealthMonitor.shared.evaluateHealth(forceCanary: false, allowNotifications: false)
        let payload = WebhookNotifier.buildPayload(snapshot: snap, title: "Disk Health Monitor Webhook Test", eventType: "test_alert")
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            completion(false, "Failed to serialize webhook JSON payload.")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                let safeErr = WebhookNotifier.redactWebhookUrl(error.localizedDescription, webhookUrl: trimmed)
                completion(false, safeErr)
                return
            }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(statusCode) {
                completion(true, "Webhook test payload delivered (HTTP \(statusCode))!")
            } else {
                let rawResp = data.flatMap { String(data: $0, encoding: .utf8) } ?? "HTTP \(statusCode)"
                let safeResp = WebhookNotifier.redactWebhookUrl(rawResp, webhookUrl: trimmed)
                completion(false, "HTTP \(statusCode): \(safeResp)")
            }
        }
        task.resume()
    }
}

// MARK: - Swift Concurrency Extensions

extension WebhookNotifier: @unchecked Sendable {
    func sendWebhook(snapshot: DiskHealthSnapshot, title: String, eventType: String = "health_alert") async -> Bool {
        await withCheckedContinuation { continuation in
            sendWebhookAsync(snapshot: snapshot, title: title, eventType: eventType) { ok in
                continuation.resume(returning: ok)
            }
        }
    }

    func sendTestWebhook(webhookUrl: String) async -> (ok: Bool, message: String) {
        await withCheckedContinuation { continuation in
            sendTestWebhook(webhookUrl: webhookUrl) { ok, msg in
                continuation.resume(returning: (ok, msg))
            }
        }
    }
}
