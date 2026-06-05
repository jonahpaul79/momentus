import AVFoundation
import EventKit
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(RecordingsStore.self) private var store

    @AppStorage("defaultRecordingMode") private var defaultModeRaw: String = RecordingMode.onDevice.rawValue
    @AppStorage("audioRetention") private var audioRetentionRaw: String = AudioRetentionPolicy.deleteAfterTranscript.rawValue
    @AppStorage("transcriptionProvider") private var transcriptionProviderRaw: String = TranscriptionProvider.appleOnDevice.rawValue
    @AppStorage("summaryProvider") private var summaryProviderRaw: String = SummaryProvider.appleFoundationModels.rawValue
    @AppStorage("showConsentPrompt") private var showConsentPrompt: Bool = false
    @AppStorage("iCloudSync") private var iCloudSync: Bool = false

    @State private var assemblyAIKey: String = ""
    @State private var assemblyAIKeySaved: Bool = false

    @State private var claudeKey: String = ""
    @State private var claudeKeySaved: Bool = false

    @State private var micPermission = AVAudioApplication.shared.recordPermission
    @State private var calPermission = EKEventStore.authorizationStatus(for: .event)
    @State private var notifStatus: UNAuthorizationStatus = .notDetermined

    private var defaultMode: RecordingMode {
        get { RecordingMode(rawValue: defaultModeRaw) ?? .onDevice }
        nonmutating set { defaultModeRaw = newValue.rawValue }
    }

    private var audioRetention: AudioRetentionPolicy {
        get { AudioRetentionPolicy(rawValue: audioRetentionRaw) ?? .deleteAfterTranscript }
        nonmutating set { audioRetentionRaw = newValue.rawValue }
    }

    var body: some View {
        let t = themeManager.currentTheme
        List {
            recordingModeSection(t)
            bestQualitySection(t)
            claudeSection(t)
            privacySection(t)
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
        .onAppear { refreshPermissions(); loadKeys() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            refreshPermissions()
        }
    }

    // MARK: - Recording Mode Section

    private func recordingModeSection(_ t: AppTheme) -> some View {
        Section {
            ForEach(RecordingMode.allCases) { mode in
                Button {
                    defaultModeRaw = mode.rawValue
                    PhoneWatchConnectivityService.shared.sendWatchCloudConfiguration()
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
            Text("This is the single provider decision. Private stays on device. Quality uses AssemblyAI for transcription and Claude if configured for summaries, with fallbacks shown above.")
                .font(t.typography.caption)
                .foregroundStyle(t.colors.textTertiary)
        }
    }

    private func modeProviderSummary(_ mode: RecordingMode) -> String {
        switch mode {
        case .onDevice:
            return "Transcript: Whisper on device. Summary: Apple on device."
        case .hybrid:
            return "Transcript: Whisper on device. Summary: Apple on device."
        case .bestQuality:
            let transcript = assemblyAIKey.isEmpty ? "Apple fallback until AssemblyAI key is saved" : "AssemblyAI"
            let summary: String
            if !claudeKey.isEmpty {
                summary = "Claude"
            } else if !assemblyAIKey.isEmpty {
                summary = "AssemblyAI LeMUR"
            } else {
                summary = "Apple fallback"
            }
            return "Transcript: \(transcript). Summary: \(summary)."
        }
    }

    // MARK: - Best Quality / AssemblyAI Section

    private func bestQualitySection(_ t: AppTheme) -> some View {
        Section {
            apiKeyRow(
                label: "AssemblyAI API Key",
                key: $assemblyAIKey,
                saved: $assemblyAIKeySaved,
                onSave: { trimmed in
                    assemblyAIKeySaved = KeychainService.store(trimmed, for: .assemblyAIAPIKey)
                    PhoneWatchConnectivityService.shared.sendWatchCloudConfiguration()
                },
                onRemove: {
                    assemblyAIKey = ""
                    KeychainService.delete(.assemblyAIAPIKey)
                    assemblyAIKeySaved = false
                    PhoneWatchConnectivityService.shared.sendWatchCloudConfiguration()
                },
                t: t
            )

            // Status
            HStack(spacing: t.spacing.s) {
                let hasKey = !assemblyAIKey.isEmpty
                Image(systemName: hasKey ? "checkmark.circle.fill" : "xmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(hasKey ? t.colors.accentSuccess : t.colors.accentWarning)
                Text(hasKey ? "Transcription: AssemblyAI (speaker labels)" : "Transcription: not configured")
                    .font(t.typography.caption)
                    .foregroundStyle(hasKey ? t.colors.accentSuccess : t.colors.accentWarning)
            }
            .listRowBackground(t.colors.surfacePrimary)

        } header: {
            sectionHeader("Best Quality — Transcription (AssemblyAI)", t: t)
        } footer: {
            Text("AssemblyAI transcribes your meetings with speaker labels. Audio is sent to AssemblyAI for processing. Transcripts are stored locally on your device only.\n\nCopy your key from assemblyai.com, then tap the row above to paste it.")
                .font(t.typography.caption)
                .foregroundStyle(t.colors.textTertiary)
        }
    }


    // MARK: - Claude / Summary Section

    private func claudeSection(_ t: AppTheme) -> some View {
        Section {
            apiKeyRow(
                label: "Anthropic API Key",
                key: $claudeKey,
                saved: $claudeKeySaved,
                onSave: { trimmed in
                    claudeKeySaved = KeychainService.store(trimmed, for: .anthropicAPIKey)
                    PhoneWatchConnectivityService.shared.sendWatchCloudConfiguration()
                },
                onRemove: {
                    claudeKey = ""
                    KeychainService.delete(.anthropicAPIKey)
                    claudeKeySaved = false
                    PhoneWatchConnectivityService.shared.sendWatchCloudConfiguration()
                },
                t: t
            )

            // Status
            HStack(spacing: t.spacing.s) {
                let hasClaudeKey     = !claudeKey.isEmpty
                let hasAssemblyAIKey = !assemblyAIKey.isEmpty
                let (icon, label, color): (String, String, Color) = {
                    if hasClaudeKey {
                        return ("checkmark.circle.fill", "Summary: Claude Sonnet", t.colors.accentSuccess)
                    } else if hasAssemblyAIKey {
                        return ("arrow.triangle.2.circlepath", "Summary: AssemblyAI LeMUR (fallback)", t.colors.accentWarning)
                    } else {
                        return ("xmark.circle", "Summary: not configured", t.colors.accentWarning)
                    }
                }()
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(color)
                Text(label).font(t.typography.caption).foregroundStyle(color)
            }
            .listRowBackground(t.colors.surfacePrimary)

        } header: {
            sectionHeader("Best Quality — Summary (Claude Sonnet)", t: t)
        } footer: {
            Text("Claude Sonnet generates structured meeting notes from the transcript. Only transcript text is sent to Anthropic — audio never leaves your device.\n\nAssemblyAI LeMUR is used automatically if no Claude key is set. Notes are stored locally only.\n\nCopy your key from console.anthropic.com, then tap the row above to paste it.")
                .font(t.typography.caption)
                .foregroundStyle(t.colors.textTertiary)
        }
    }

    // MARK: - Shared API Key Row

    @ViewBuilder
    private func apiKeyRow(
        label: String,
        key: Binding<String>,
        saved: Binding<Bool>,
        onSave: @escaping (String) -> Void,
        onRemove: @escaping () -> Void,
        t: AppTheme
    ) -> some View {
        if saved.wrappedValue {
            HStack(spacing: t.spacing.m) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(label)
                        .font(t.typography.headlineSmall)
                        .foregroundStyle(t.colors.textPrimary)
                    Text(maskedKey(key.wrappedValue))
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(t.colors.textSecondary)
                }
                Spacer()
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(t.typography.labelLarge)
                    .foregroundStyle(t.colors.accentSuccess)
            }
            .padding(.vertical, t.spacing.s)
            .listRowBackground(t.colors.surfacePrimary)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    onRemove()
                    HapticStyle.medium.trigger()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
            }
        } else {
            Button {
                guard let pasted = UIPasteboard.general.string?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !pasted.isEmpty else { return }
                key.wrappedValue = pasted
                onSave(pasted)
                HapticStyle.light.trigger()
            } label: {
                HStack(spacing: t.spacing.m) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(label)
                            .font(t.typography.headlineSmall)
                            .foregroundStyle(t.colors.textPrimary)
                        Text("Tap to paste from clipboard")
                            .font(t.typography.bodySmall)
                            .foregroundStyle(t.colors.textTertiary)
                    }
                    Spacer()
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 22))
                        .foregroundStyle(t.colors.accentPrimary)
                }
                .padding(.vertical, t.spacing.m)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .listRowBackground(t.colors.surfacePrimary)
        }
    }

    private func maskedKey(_ key: String) -> String {
        guard key.count > 6 else { return String(repeating: "•", count: key.count) }
        return String(key.prefix(6)) + "••••••••••••"
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

            // Consent prompt
            Toggle(isOn: $showConsentPrompt) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show recording consent")
                        .foregroundStyle(t.colors.textPrimary)
                    Text("Display a reminder before each meeting")
                        .font(t.typography.caption)
                        .foregroundStyle(t.colors.textSecondary)
                }
            }
            .tint(t.colors.accentPrimary)
            .listRowBackground(t.colors.surfacePrimary)

        } header: {
            sectionHeader("Privacy", t: t)
        } footer: {
            Text("No meeting content is used for training by this app.")
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
                 ? "Notes and transcripts sync across your devices via iCloud. Audio files are not synced."
                 : "Enable to sync notes and transcripts across your devices.")
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
                Text("1.0 (MVP)")
                    .foregroundStyle(t.colors.textSecondary)
            }
            .listRowBackground(t.colors.surfacePrimary)

            HStack {
                Text("Build")
                    .foregroundStyle(t.colors.textPrimary)
                Spacer()
                Text("2026.05")
                    .foregroundStyle(t.colors.textSecondary)
            }
            .listRowBackground(t.colors.surfacePrimary)
        } header: {
            sectionHeader("About", t: t)
        } footer: {
            Text("Momentus MVP · Dark mode by default · Privacy first")
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

    private func loadKeys() {
        assemblyAIKey      = KeychainService.retrieve(.assemblyAIAPIKey) ?? ""
        claudeKey          = KeychainService.retrieve(.anthropicAPIKey)  ?? ""
        assemblyAIKeySaved = !assemblyAIKey.isEmpty
        claudeKeySaved     = !claudeKey.isEmpty
    }

    private func refreshPermissions() {
        micPermission = AVAudioApplication.shared.recordPermission
        calPermission = EKEventStore.authorizationStatus(for: .event)
        Task { notifStatus = await MeetingNotificationService.shared.authorizationStatus() }
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
