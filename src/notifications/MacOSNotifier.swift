import Foundation
import UserNotifications
import AppKit

// MARK: - Native macOS Notifications

final class MacOSNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MacOSNotifier()
    private var isAuthorized = false

    override private init() {
        super.init()
        guard Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            self.isAuthorized = granted
            if let err = error {
                ConfigManager.shared.log("Notification authorization error: \(err.localizedDescription)")
            }
        }
    }

    func postNotification(title: String, subtitle: String, body: String, identifier: String = UUID().uuidString) {
        guard Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil else { return }
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
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
