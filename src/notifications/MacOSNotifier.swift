import Foundation
import UserNotifications
import AppKit

// MARK: - Native macOS Notifications

final class MacOSNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MacOSNotifier()
    private var isAuthorized = false

    private var isAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    override private init() {
        super.init()
        guard isAppBundle else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            self.isAuthorized = granted
            if let err = error {
                ConfigManager.shared.log("Notification authorization error: \(err.localizedDescription)")
            }
        }
    }

    static func escapeAppleScriptLiteral(_ raw: String) -> String {
        return raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\0", with: "")
    }

    func postNotification(title: String, subtitle: String, body: String, identifier: String = UUID().uuidString) {
        if isAppBundle {
            let content = UNMutableNotificationContent()
            content.title = title
            if !subtitle.isEmpty { content.subtitle = subtitle }
            content.body = body
            content.sound = UNNotificationSound.default

            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    ConfigManager.shared.log("Failed to deliver native notification: \(error.localizedDescription)")
                }
            }
        } else {
            // Standalone CLI binary fallback via osascript
            let safeTitle = MacOSNotifier.escapeAppleScriptLiteral(title)
            let safeSub = MacOSNotifier.escapeAppleScriptLiteral(subtitle)
            let safeBody = MacOSNotifier.escapeAppleScriptLiteral(body)
            let script = subtitle.isEmpty
                ? "display notification \"\(safeBody)\" with title \"\(safeTitle)\""
                : "display notification \"\(safeBody)\" with title \"\(safeTitle)\" subtitle \"\(safeSub)\""
            DispatchQueue.global(qos: .utility).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                proc.arguments = ["-e", script]
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice
                try? proc.run()
                proc.waitUntilExit()
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
