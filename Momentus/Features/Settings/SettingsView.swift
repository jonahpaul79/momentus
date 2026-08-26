import AVFoundation
import EventKit
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(RecordingsStore.self) private var store

    @AppStorage("defaultRecordingMode") private var defaultModeRaw: String = RecordingMode.onDevice.rawValue
    @AppStorage("audioRetention") private var audioRetentionRaw: String = AudioRetentionPolicy.keepForever.rawValue
    @AppStorage("transcriptionProvider") private var transcriptionProviderRaw: String = TranscriptionProvider.appleOnDevice.rawValue
    @AppStorage("summaryProvider") private var summaryProviderRaw: String = SummaryProvider.appleFoundationModels.rawValue
    @AppStorage(CloudAIConsent.preferenceKey) private var cloudAIConsentVersion: String = ""
    @AppStorage("iCloudSync") private var iCloudSync: Bool = false

    @State private var micPermission = AVAudioApplication.shared.recordPermission
    @State private var calPermission = EKEventStore.authorizationStatus(for: .event)
    @State private var notifStatus: UNAuthorizationStatus = .notDetermined
    @State private var showingWidgetEducation = false
    @State private var showingCloudAIConsent = false
    @State private var pendingDefaultMode: RecordingMode?
    @State private var iPhoneWidgetInstalled = false

    private var defaultMode: RecordingMode {
        get { RecordingMode(rawValue: defaultModeRaw) ?? .onDevice }
        nonmutating set { defaultModeRaw = newValue.rawValue }
    }

    private var audioRetention: AudioRetentionPolicy {
        get { AudioRetentionPolicy(rawValue: audioRetentionRaw) ?? .keepForever }
        nonmutating set { audioRetentionRaw = newValue.rawValue }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    var body: some View {
        let t = themeManager.currentTheme
        List {
            recordingModeSection(t)
            privacySection(t)
            quickRecordSection(t)
            permissionsSection(t)
            storageSection(t)
            themeSection(t)
            aboutSection(t)
        }
        .scrollContentBackground(.hidden)
        .background(t.colors.backgroundPrimary)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .listStyle(.insetGrouped)
        .onAppear { refreshPermissions(); refreshWidgetStatus() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            refreshPermissions()
            refreshWidgetStatus()
        }
        .sheet(isPresented: $showingWidgetEducation) {
            WidgetEducationView(iPhoneWidgetInstalled: iPhoneWidgetInstalled)
                .environment(themeManager)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingCloudAIConsent) {
            CloudAIConsentView(
                onAllow: {
                    cloudAIConsentVersion = CloudAIConsent.currentVersion
                    if let pendingDefaultMode {
                        defaultModeRaw = pendingDefaultMode.rawValue
                        syncWatchProviderConfig()
                    }
                    pendingDefaultMode = nil
                },
                onUsePrivate: {
                    defaultModeRaw = RecordingMode.onDevice.rawValue
                    pendingDefaultMode = nil
                    syncWatchProviderConfig()
                }
            )
            .environment(themeManager)
        }
    }

    // MARK: - Recording Mode Section

    private func recordingModeSection(_ t: AppTheme) -> some View {
        Section {
            ForEach(RecordingMode.allCases) { mode in
                Button {
                    if mode.usesCloud, !CloudAIConsent.isGranted {
                        pendingDefaultMode = mode
                        showingCloudAIConsent = true
                    } else {
                        defaultModeRaw = mode.rawValue
                        syncWatchProviderConfig()
                    }
                    HapticStyle.light.trigger()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: t.spacing.s) {
                                Image(systemName: mode.icon)
                                    .font(.system(size: 14))
                                    .foregroundStyle(modeColor(mode, t: t))
                                    .frame(width: 20)
                                Text(mode.displayName)
                                    .font(t.typography.headlineSmall)
                                    .foregroundStyle(t.colors.textPrimary)
                            }
                            Text(mode.description)
                                .font(t.typography.caption)
                                .foregroundStyle(t.colors.textSecondary)
                                .padding(.leading, 28)
                            Text(modeProviderSummary(mode))
                                .font(t.typography.caption)
                                .foregroundStyle(t.colors.textTertiary)
                                .padding(.leading, 28)
                        }
                        Spacer()
                        if defaultModeRaw == mode.rawValue {
                            Image(systemName: "checkmark")
                                .foregroundStyle(t.colors.accentPrimary)
                                .font(.system(size: 14, weight: .semibold))
                        }
                    }
                    .padding(.vertical, t.spacing.xs)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .listRowBackground(t.colors.surfacePrimary)
            }
        } header: {
            sectionHeader("Default Recording Mode", t: t)
        } footer: {
            Text("This is the single provider decision. Private stays on device. Quality uses Momentus Cloud, with automatic fallbacks shown above.")
                .font(t.typography.caption)
                .foregroundStyle(t.colors.textTertiary)
        }
    }

    private func modeProviderSummary(_ mode: RecordingMode) -> String {
        switch mode {
        case .onDevice:
            return "Transcript: Whisper on device. Summary: Apple on device."
        case .hybrid:
            return "Transcript: Whisper on device. Summary: Momentus Cloud."
        case .bestQuality:
            return "Transcript: AssemblyAI. Summary: Claude via Momentus Cloud."
        }
    }

    // MARK: - Privacy Section

    private func privacySection(_ t: AppTheme) -> some View {
        Section {
            // Audio retention
            Picker(selection: $audioRetentionRaw) {
                ForEach(AudioRetentionPolicy.allCases) { policy in
                    Text(policy.displayName)
                        .tag(policy.rawValue)
                }
            } label: {
                Label("Keep raw audio", systemImage: "waveform")
                    .foregroundStyle(t.colors.textPrimary)
            }
            .tint(t.colors.accentPrimary)
            .listRowBackground(t.colors.surfacePrimary)
            .onChange(of: audioRetentionRaw) { _, _ in
                Task { await store.applyAudioRetentionPolicy() }
            }

            Toggle(isOn: Binding(
                get: { cloudAIConsentVersion == CloudAIConsent.currentVersion },
                set: { enabled in
                    if enabled {
                        showingCloudAIConsent = true
                    } else {
                        cloudAIConsentVersion = ""
                        CloudAIConsent.revoke()
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow Cloud AI processing")
                        .foregroundStyle(t.colors.textPrimary)
                    Text("Share meeting data with AssemblyAI and Anthropic")
                        .font(t.typography.caption)
                        .foregroundStyle(t.colors.textSecondary)
                }
            }
            .tint(t.colors.accentPrimary)
            .listRowBackground(t.colors.surfacePrimary)

            Link(destination: URL(string: "https://momentusnotes.com/privacy")!) {
                Label("Privacy Policy", systemImage: "hand.raised")
                    .foregroundStyle(t.colors.textPrimary)
            }
            .listRowBackground(t.colors.surfacePrimary)

            Link(destination: URL(string: "https://momentusnotes.com/ai-data")!) {
                Label("AI Data Details", systemImage: "sparkles.rectangle.stack")
                    .foregroundStyle(t.colors.textPrimary)
            }
            .listRowBackground(t.colors.surfacePrimary)

        } header: {
            sectionHeader("Privacy", t: t)
        } footer: {
            Text("Turn Cloud AI off here at any time. Private mode remains on device.")
                .font(t.typography.caption)
                .foregroundStyle(t.colors.textTertiary)
        }
    }

    // MARK: - Storage Section

    private func storageSection(_ t: AppTheme) -> some View {
        Section {
            HStack {
                Label("Storage", systemImage: "internaldrive")
                    .foregroundStyle(t.colors.textPrimary)
                Spacer()
                Text("Local")
                    .font(t.typography.bodySmall)
                    .foregroundStyle(t.colors.textSecondary)
            }
            .listRowBackground(t.colors.surfacePrimary)

            Toggle(isOn: $iCloudSync) {
                HStack(spacing: t.spacing.s) {
                    Label("iCloud Sync", systemImage: "icloud")
                        .foregroundStyle(t.colors.textPrimary)
                    if store.isSyncing {
                        ProgressView()
                            .scaleEffect(0.7)
                            .tint(t.colors.accentPrimary)
                    }
                }
            }
            .tint(t.colors.accentPrimary)
            .listRowBackground(t.colors.surfacePrimary)
            .onChange(of: iCloudSync) { _, enabled in
                if enabled { Task { await store.enableCloudSync() } }
            }

        } header: {
            sectionHeader("Storage", t: t)
        } footer: {
            Text(iCloudSync
                 ? "Recordings, transcripts, and notes sync through your private iCloud database. Raw audio follows the retention period above."
                 : "Enable to sync recordings, transcripts, and notes across your devices.")
                .font(t.typography.caption)
                .foregroundStyle(t.colors.textTertiary)
        }
    }

    // MARK: - Theme Section

    private func themeSection(_ t: AppTheme) -> some View {
        Section {
            ForEach(ThemePreset.allCases) { preset in
                Button {
                    themeManager.currentPreset = preset
                    HapticStyle.light.trigger()
                } label: {
                    HStack(spacing: t.spacing.m) {
                        themePreviewSwatch(preset)
                        Text(preset.displayName)
                            .foregroundStyle(t.colors.textPrimary)
                        Spacer()
                        if themeManager.currentPreset == preset {
                            Image(systemName: "checkmark")
                                .foregroundStyle(t.colors.accentPrimary)
                                .font(.system(size: 14, weight: .semibold))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .listRowBackground(t.colors.surfacePrimary)
            }
        } header: {
            sectionHeader("Theme", t: t)
        }
    }

    private func themePreviewSwatch(_ preset: ThemePreset) -> some View {
        let (bg, accent) = preset.previewColors
        return HStack(spacing: 0) {
            bg.frame(width: 20, height: 28)
            accent.frame(width: 10, height: 28)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
    }

    // MARK: - About Section

    private func aboutSection(_ t: AppTheme) -> some View {
        Section {
            HStack {
                Text("Version")
                    .foregroundStyle(t.colors.textPrimary)
                Spacer()
                Text(appVersion)
                    .foregroundStyle(t.colors.textSecondary)
            }
            .listRowBackground(t.colors.surfacePrimary)

            HStack {
                Text("Build")
                    .foregroundStyle(t.colors.textPrimary)
                Spacer()
                Text(appBuild)
                    .foregroundStyle(t.colors.textSecondary)
            }
            .listRowBackground(t.colors.surfacePrimary)

        } header: {
            sectionHeader("About", t: t)
        }
    }

    // MARK: - Quick Record Section

    private func quickRecordSection(_ t: AppTheme) -> some View {
        Section {
            Button {
                showingWidgetEducation = true
                HapticStyle.light.trigger()
            } label: {
                HStack(spacing: t.spacing.m) {
                    Image(systemName: "mic.badge.plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(t.colors.accentPrimary)
                        .frame(width: 32, height: 32)
                        .background(t.colors.accentPrimary.opacity(0.12))
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Quick Record Widget")
                            .font(t.typography.headlineSmall)
                            .foregroundStyle(t.colors.textPrimary)
                        Text(iPhoneWidgetInstalled ? "Installed on this iPhone" : "Setup instructions for iPhone and Apple Watch")
                            .font(t.typography.caption)
                            .foregroundStyle(iPhoneWidgetInstalled
                                ? t.colors.accentSuccess
                                : t.colors.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(t.colors.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(t.colors.surfacePrimary)
        } header: {
            sectionHeader("Quick Record", t: t)
        } footer: {
            Text("Start recording from your Home Screen, Lock Screen, Apple Watch face, or Smart Stack.")
                .font(t.typography.caption)
                .foregroundStyle(t.colors.textTertiary)
        }
    }

    // MARK: - Permissions Section

    private func permissionsSection(_ t: AppTheme) -> some View {
        Section {
            permissionRow(
                icon: "mic.fill",
                title: "Microphone",
                description: "Required to record meetings",
                isGranted: micPermission == .granted,
                isDenied: micPermission == .denied,
                t: t
            ) {
                Task {
                    _ = await AVAudioApplication.requestRecordPermission()
                    micPermission = AVAudioApplication.shared.recordPermission
                }
            }

            permissionRow(
                icon: "calendar",
                title: "Calendar",
                description: "Suggests meeting titles from your schedule",
                isGranted: calPermission == .fullAccess,
                isDenied: calPermission == .denied || calPermission == .restricted,
                t: t
            ) {
                Task {
                    _ = try? await EKEventStore().requestFullAccessToEvents()
                    calPermission = EKEventStore.authorizationStatus(for: .event)
                }
            }

            permissionRow(
                icon: "bell.fill",
                title: "Notifications",
                description: "Reminds you 1 minute before meetings start",
                isGranted: notifStatus == .authorized || notifStatus == .provisional,
                isDenied: notifStatus == .denied,
                t: t
            ) {
                Task {
                    _ = await MeetingNotificationService.shared.requestAuthorization()
                    notifStatus = await MeetingNotificationService.shared.authorizationStatus()
                }
            }
        } header: {
            sectionHeader("Permissions", t: t)
        } footer: {
            Text("Denied permissions can only be changed in iOS Settings.")
                .font(t.typography.caption)
                .foregroundStyle(t.colors.textTertiary)
        }
    }

    @ViewBuilder
    private func permissionRow(
        icon: String,
        title: String,
        description: String,
        isGranted: Bool,
        isDenied: Bool,
        t: AppTheme,
        onRequest: @escaping () -> Void
    ) -> some View {
        HStack(spacing: t.spacing.m) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(isGranted ? t.colors.accentSuccess : t.colors.accentPrimary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(t.typography.headlineSmall)
                    .foregroundStyle(t.colors.textPrimary)
                Text(description)
                    .font(t.typography.caption)
                    .foregroundStyle(t.colors.textSecondary)
            }
            Spacer()
            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(t.colors.accentSuccess)
                    .font(.system(size: 18))
            } else if isDenied {
                Button("Open Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .font(t.typography.caption)
                .foregroundStyle(t.colors.accentPrimary)
                .buttonStyle(PlainButtonStyle())
            } else {
                Button("Allow") { onRequest() }
                    .font(t.typography.caption)
                    .foregroundStyle(t.colors.accentPrimary)
                    .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.vertical, t.spacing.xs)
        .listRowBackground(t.colors.surfacePrimary)
    }

    // MARK: - Helpers

    private func refreshPermissions() {
        micPermission = AVAudioApplication.shared.recordPermission
        calPermission = EKEventStore.authorizationStatus(for: .event)
        Task { notifStatus = await MeetingNotificationService.shared.authorizationStatus() }
    }

    private func refreshWidgetStatus() {
        Task {
            iPhoneWidgetInstalled = await QuickRecordWidgetStatus.isIPhoneWidgetInstalled()
        }
    }

    private func syncWatchProviderConfig() {
        PhoneWatchConnectivityService.shared.sendWatchCloudConfiguration()
        Task { await CloudKitService.shared.saveCurrentProviderConfig() }
    }

    private func sectionHeader(_ title: String, t: AppTheme) -> some View {
        Text(title)
            .font(t.typography.labelLarge)
            .foregroundStyle(t.colors.textSecondary)
            .textCase(.uppercase)
    }

    private func modeColor(_ mode: RecordingMode, t: AppTheme) -> Color {
        switch mode {
        case .onDevice: return t.colors.accentSuccess
        case .bestQuality: return t.colors.accentPrimary
        case .hybrid: return t.colors.accentSecondary
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
    .environment(ThemeManager())
    .environment(RecordingsStore(loadSamples: false))
    .preferredColorScheme(.dark)
}
