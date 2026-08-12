import ActivityKit
import Foundation

struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var isPaused: Bool
        var markerCount: Int
        var elapsedTime: TimeInterval
        var timerStartedAt: Date?
    }

    var recordingID: UUID
    var title: String
    var startedAt: Date
}
