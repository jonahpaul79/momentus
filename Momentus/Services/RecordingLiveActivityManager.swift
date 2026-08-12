import ActivityKit
import Foundation

@MainActor
final class RecordingLiveActivityManager {
    static let shared = RecordingLiveActivityManager()

    private var activity: Activity<RecordingActivityAttributes>?

    private init() {}

    func start(recordingID: UUID, title: String, startedAt: Date = Date()) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        if let activity {
            await activity.end(nil, dismissalPolicy: .immediate)
        }

        let attributes = RecordingActivityAttributes(
            recordingID: recordingID,
            title: title,
            startedAt: startedAt
        )
        let state = RecordingActivityAttributes.ContentState(
            isPaused: false,
            markerCount: 0,
            elapsedTime: 0,
            timerStartedAt: startedAt
        )

        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
        } catch {
            print("[Live Activity] Could not start: \(error.localizedDescription)")
        }
    }

    func update(isPaused: Bool, markerCount: Int, elapsedTime: TimeInterval) async {
        guard let activity else { return }
        let state = RecordingActivityAttributes.ContentState(
            isPaused: isPaused,
            markerCount: markerCount,
            elapsedTime: elapsedTime,
            timerStartedAt: isPaused ? nil : Date()
        )
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }

    func end() async {
        guard let activity else { return }
        let state = RecordingActivityAttributes.ContentState(
            isPaused: false,
            markerCount: activity.content.state.markerCount,
            elapsedTime: activity.content.state.elapsedTime,
            timerStartedAt: nil
        )
        await activity.end(
            ActivityContent(state: state, staleDate: nil),
            dismissalPolicy: .after(.now + 8)
        )
        self.activity = nil
    }
}
