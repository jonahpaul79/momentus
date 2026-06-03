import SwiftUI

struct ContentView: View {
    @State private var themeManager = ThemeManager()
    @State private var store = RecordingsStore(loadSamples: ContentView.shouldLoadDemoData)
    @State private var selectedTab = Tab.record
    @State private var showingSplash = true
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    enum Tab: String { case record, notes, settings }

    private static var shouldLoadDemoData: Bool {
        #if targetEnvironment(simulator)
        return true
        #elseif DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-demoMode")
            || arguments.contains("demoMode")
            || UserDefaults.standard.bool(forKey: "demoMode")
        #else
        return false
        #endif
    }

    var body: some View {
        let t = themeManager.currentTheme
        Group {
            if !hasCompletedOnboarding {
                OnboardingView()
                    .environment(themeManager)
            } else {
                mainTabs(t)
            }
        }
        .environment(themeManager)
        .environment(store)
        .preferredColorScheme(themeManager.currentTheme.colorScheme)
        .overlay {
            if showingSplash {
                SplashView(isVisible: $showingSplash)
                    .environment(themeManager)
            }
        }
    }

    private func mainTabs(_ t: AppTheme) -> some View {
        TabView(selection: $selectedTab) {
            NavigationStack { NotesListView() }
                .tabItem { Label("Notes", systemImage: "doc.text") }
                .tag(Tab.notes)

            NavigationStack { RecordHomeView() }
                .tabItem { Label("Record", systemImage: "mic") }
                .tag(Tab.record)

            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .tint(t.colors.accentPrimary)
        .toolbarBackground(t.colors.backgroundSecondary.opacity(0.97), for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .onReceive(NotificationCenter.default.publisher(for: .recordingProcessingCompleted)) { _ in
            selectedTab = .notes
        }
        .onReceive(NotificationCenter.default.publisher(for: .autoStartRecording)) { _ in
            selectedTab = .record
        }
    }
}

#Preview {
    ContentView()
        .environment(RecordingsStore(loadSamples: true))
}
