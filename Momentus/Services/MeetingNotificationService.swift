import UserNotifications

final class MeetingNotificationService {
    static let shared = MeetingNotificationService()
    private init() {}

    private let requestPrefix = "meeting-reminder-"

    // MARK: - Authorization

    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    // MARK: - Scheduling

    func scheduleReminders(for meetings: [CalendarMeeting]) async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }

        let pending = await center.pendingNotificationRequests()
        let existingIDs = pending.map(\.identifier).filter { $0.hasPrefix(requestPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: existingIDs)

        for meeting in meetings {
            let fireDate = meeting.startDate.addingTimeInterval(-60)
            guard fireDate > Date() else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Meeting starting soon"
            content.body = "\"\(meeting.title)\" starts in 1 minute. Tap to record."
            content.sound = .default
            content.userInfo = ["action": "startRecording", "meetingTitle": meeting.title]

            let comps = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: fireDate
            )
            let request = UNNotificationRequest(
                identifier: requestPrefix + meeting.id.uuidString,
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            )
            try? await center.add(request)
        }
    }

    func cancelAll() {
        let center = UNUserNotificationCenter.current()
        Task {
            let pending = await center.pendingNotificationRequests()
            let ids = pending.map(\.identifier).filter { $0.hasPrefix(requestPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }
}
