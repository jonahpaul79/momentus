import AppIntents
import Foundation

enum WatchQuickRecordLaunchRequest {
    private static let pendingKey = "momentus.watch.pendingQuickRecord"

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

struct StartMomentusWatchRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Recording"
    static var description = IntentDescription("Open Momentus on your watch and immediately start recording.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await MainActor.run { WatchQuickRecordLaunchRequest.requestStart() }
        return .result()
    }
}
