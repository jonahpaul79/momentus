import EventKit
import UIKit
import UserNotifications

final class MomentusAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([Self.meetingReminderCategory])
        return true
    }

    static let meetingReminderCategory: UNNotificationCategory = {
        let action = UNNotificationAction(
            identifier: "startRecordingAction",
            title: "Record",
            options: [.foreground]
        )
        return UNNotificationCategory(
            identifier: "meetingReminder",
            actions: [action],
            intentIdentifiers: [],
            options: []
        )
    }()

    func applicationDidBecomeActive(_ application: UIApplication) {
        Task { await refreshNotificationSchedule() }
    }

    private func refreshNotificationSchedule() async {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        let service = EventKitCalendarService()
        let meetings = await service.getCurrentMeetings() + service.getUpcomingMeetings()
        await MeetingNotificationService.shared.scheduleReminders(for: meetings)
    }
}

extension MomentusAppDelegate: UNUserNotificationCenterDelegate {
    // Show banner + play sound even when the app is foregrounded
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // Tapping the notification fires autoStartRecording — ContentView switches tabs,
    // RecordHomeView picks it up and starts recording.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        switch info["action"] as? String {
        case "startRecording":
            NotificationCenter.default.post(name: .autoStartRecording, object: nil, userInfo: info)
        case "viewSummary":
            if let idStr = info["recordingId"] as? String, let id = UUID(uuidString: idStr) {
                NotificationCenter.default.post(
                    name: .recordingProcessingCompleted,
                    object: nil,
                    userInfo: ["recordingId": id]
                )
            }
        default:
            break
        }
        completionHandler()
    }
}
