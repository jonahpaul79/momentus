import SwiftUI

struct ContentView: View {
    @State private var themeManager = ThemeManager()
    @State private var store = RecordingsStore(loadSamples: ContentView.shouldLoadDemoData)
    @State private var selectedTab = Tab.record
    @State private var showingSplash = true
    @State private var showingWidgetEducation = false
    @State private var checkingWidgetConfiguration = false
    @State private var iPhoneWidgetInstalled = false
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("hasSeenQuickRecordWidgetIntroV1") private var hasSeenQuickRecordWidgetIntro = false

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
        .sheet(isPresented: $showingWidgetEducation) {
            hasSeenQuickRecordWidgetIntro = true
        } content: {
            WidgetEducationView(iPhoneWidgetInstalled: iPhoneWidgetInstalled)
                .environment(themeManager)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .task {
            WatchRecordingProcessor.shared.configure(store: store)
            await CloudKitService.shared.saveCurrentProviderConfig()
            await store.importCloudRecordingsWithRetry()
            await store.applyAudioRetentionPolicy()
            await store.processPendingRemoteTranscriptDeletions()
            store.resumeInterruptedProcessing()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await store.importCloudRecordingsWithRetry()
                await store.applyAudioRetentionPolicy()
                await store.processPendingRemoteTranscriptDeletions()
                store.resumeInterruptedProcessing()
            }
        }
        .onChange(of: showingSplash) { _, isShowing in
            if !isShowing { presentWidgetEducationIfNeeded() }
        }
        .onChange(of: hasCompletedOnboarding) { _, completed in
            if completed { presentWidgetEducationIfNeeded() }
        }
        .overlay {
            if showingSplash {
                SplashView(isVisible: $showingSplash)
                    .environment(themeManager)
            }
        }
    }

    private func presentWidgetEducationIfNeeded() {
        guard hasCompletedOnboarding,
              !showingSplash,
              !hasSeenQuickRecordWidgetIntro,
              !showingWidgetEducation,
              !checkingWidgetConfiguration else { return }

        checkingWidgetConfiguration = true
        Task {
            let installed = await QuickRecordWidgetStatus.isIPhoneWidgetInstalled()
            iPhoneWidgetInstalled = installed
            checkingWidgetConfiguration = false

            guard hasCompletedOnboarding,
                  !showingSplash,
                  !hasSeenQuickRecordWidgetIntro else { return }
            showingWidgetEducation = true
        }
    }

    private func mainTabs(_ t: AppTheme) -> some View {
        TabView(selection: $selectedTab) {
            NavigationStack { NotesListView() }
                .tabItem { Label("Notes", systemImage: "doc.text") }
                .tag(Tab.notes)

            NavigationStack {
                RecordHomeView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
                .tabItem { Label("Record", systemImage: "mic") }
                .tag(Tab.record)

            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(t.colors.backgroundPrimary.ignoresSafeArea())
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
