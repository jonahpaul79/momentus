import SwiftUI

struct ContentView: View {
    @State private var themeManager = ThemeManager()
    @State private var store = RecordingsStore(loadSamples: false)
    @State private var selectedTab = Tab.record
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    enum Tab: String { case record, notes, settings }

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
        .preferredColorScheme(.dark)
    }

    private func mainTabs(_ t: AppTheme) -> some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                RecordHomeView()
            }
            .tabItem {
                Label("Record", systemImage: "mic.circle.fill")
            }
            .tag(Tab.record)

            NavigationStack {
                NotesListView()
            }
            .tabItem {
                Label("Notes", systemImage: "doc.text.fill")
            }
            .tag(Tab.notes)

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape.fill")
            }
            .tag(Tab.settings)
        }
        .tint(t.colors.accentPrimary)
        .toolbarBackground(t.colors.backgroundSecondary.opacity(0.97), for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }
}

#Preview {
    ContentView()
        .environment(RecordingsStore(loadSamples: true))
}
