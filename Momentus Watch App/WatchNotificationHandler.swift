import UserNotifications

extension Notification.Name {
    static let autoStartRecording = Notification.Name("autoStartRecording")
}

final class WatchNotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = WatchNotificationHandler()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if (info["action"] as? String) == "startRecording" {
            NotificationCenter.default.post(name: .autoStartRecording, object: nil)
        }
        completionHandler()
    }
}
