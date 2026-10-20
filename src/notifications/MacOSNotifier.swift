import Foundation
import UserNotifications
import AppKit

// MARK: - Native macOS Notifications

final class MacOSNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MacOSNotifier()
    private let stateLock = NSLock()
    private var isAuthorized = false

    static var hasValidAppBundle: Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        if Bundle.main.bundleURL.pathExtension == "app" {
            return true
        }
        if let execURL = Bundle.main.executableURL?.resolvingSymlinksInPath(),
           execURL.path.contains(".app/Contents/MacOS/") {
            return true
        }
        return false
    }

    override private init() {
        super.init()
        guard MacOSNotifier.hasValidAppBundle else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            self?.stateLock.lock()
            self?.isAuthorized = granted
            self?.stateLock.unlock()
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

    func postNotification(title: String, subtitle: String, body: String, identifier: String = "disk-health-status") {
        guard MacOSNotifier.hasValidAppBundle else {
            ConfigManager.shared.log("Skipping desktop banner (process is not running inside an .app bundle): \(title)")
            return
        }

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                ConfigManager.shared.log("Desktop notification suppressed (authorizationStatus=\(settings.authorizationStatus.rawValue)): \(title)")
                return
            }

            let content = UNMutableNotificationContent()
            content.title = title
            if !subtitle.isEmpty { content.subtitle = subtitle }
            content.body = body
            content.sound = UNNotificationSound.default

            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            center.add(request) { error in
                if let error = error {
                    ConfigManager.shared.log("Failed to deliver native notification: \(error.localizedDescription)")
                }
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
