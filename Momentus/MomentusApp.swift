import SwiftUI

@main
struct MomentusApp: App {
    @UIApplicationDelegateAdaptor(MomentusAppDelegate.self) var appDelegate

    init() {
        _ = PhoneWatchConnectivityService.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
