import SwiftUI

@main
struct MomentusApp: App {
    init() {
        _ = PhoneWatchConnectivityService.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
