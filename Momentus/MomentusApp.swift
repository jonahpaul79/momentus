import SwiftUI

@main
struct MomentusApp: App {
    @UIApplicationDelegateAdaptor(MomentusAppDelegate.self) var appDelegate

    init() {
        _ = PhoneWatchConnectivityService.shared
        // Begin downloading/loading the Whisper model immediately so it is ready
        // before the user's first Private Mode recording completes.
        WhisperKitTranscriptionService.warmup()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
