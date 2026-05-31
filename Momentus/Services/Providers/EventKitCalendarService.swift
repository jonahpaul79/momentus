import EventKit
import Foundation

final class EventKitCalendarService: CalendarContextService {
    private let store = EKEventStore()

    func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    func getCurrentMeetings() async -> [CalendarMeeting] {
        guard hasAccess else { return [] }
        let now = Date()
        return events(from: now.addingTimeInterval(-3600), to: now)
            .filter { $0.startDate <= now && $0.endDate >= now }
            .map(\.calendarMeeting)
    }

    func getUpcomingMeetings() async -> [CalendarMeeting] {
        guard hasAccess else { return [] }
        let now = Date()
        let horizon = now.addingTimeInterval(4 * 3600)
        return events(from: now, to: horizon)
            .filter { $0.startDate > now }
            .sorted { $0.startDate < $1.startDate }
            .map(\.calendarMeeting)
    }

    private var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    private func events(from start: Date, to end: Date) -> [EKEvent] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
    }
}

private extension EKEvent {
    var calendarMeeting: CalendarMeeting {
        CalendarMeeting(
            id: UUID(),
            title: title ?? "Untitled",
            startDate: startDate,
            endDate: endDate,
            attendees: attendees?.compactMap { $0.name } ?? []
        )
    }
}
