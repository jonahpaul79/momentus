import AppIntents
import Foundation

enum QuickRecordLaunchRequest {
    private static let pendingKey = "momentus.pendingQuickRecord"

    static func requestStart() {
        UserDefaults.standard.set(true, forKey: pendingKey)
        NotificationCenter.default.post(name: Notification.Name("autoStartRecording"), object: nil)
    }

    static func consumePendingStart() -> Bool {
        guard UserDefaults.standard.bool(forKey: pendingKey) else { return false }
        UserDefaults.standard.set(false, forKey: pendingKey)
        return true
    }
}

struct StartMomentusRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Recording"
    static var description = IntentDescription("Open Momentus and immediately start a new recording.")
    static var supportedModes: IntentModes = .foreground(.immediate)

    func perform() async throws -> some IntentResult {
        await MainActor.run { QuickRecordLaunchRequest.requestStart() }
        return .result()
    }
}

struct ToggleMomentusRecordingIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Pause or Resume Recording"

    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: Notification.Name("toggleActiveRecording"), object: nil)
        return .result()
    }
}

struct MarkMomentusRecordingIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Mark Moment"

    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: Notification.Name("markActiveRecording"), object: nil)
        return .result()
    }
}

struct StopMomentusRecordingIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop Recording"

    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: Notification.Name("stopActiveRecording"), object: nil)
        return .result()
    }
}
