import SwiftUI

@main
struct MomentusApp: App {
    @UIApplicationDelegateAdaptor(MomentusAppDelegate.self) var appDelegate

    init() {
        _ = PhoneWatchConnectivityService.shared
        // Begin downloading/loading the Whisper model immediately so it is ready
        // before the user's first Private Mode recording completes.
        // Unit-test hosts do not need the 250 MB model and can terminate while
        // WhisperKit is bootstrapping before XCTest establishes its connection.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            WhisperKitTranscriptionService.warmup()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
