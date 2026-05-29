import SwiftUI

struct SettingsView: View {
    @Environment(ThemeManager.self) private var themeManager

    @AppStorage("defaultRecordingMode") private var defaultModeRaw: String = RecordingMode.onDevice.rawValue
    @AppStorage("audioRetention") private var audioRetentionRaw: String = AudioRetentionPolicy.deleteAfterTranscript.rawValue
    @AppStorage("transcriptionProvider") private var transcriptionProviderRaw: String = TranscriptionProvider.appleOnDevice.rawValue
    @AppStorage("summaryProvider") private var summaryProviderRaw: String = SummaryProvider.appleFoundationModels.rawValue
    @AppStorage("showConsentPrompt") private var showConsentPrompt: Bool = false
    @AppStorage("iCloudSync") private var iCloudSync: Bool = false

    @State private var assemblyAIKey: String = ""
    @State private var showAssemblyAIKey: Bool = false
    @State private var assemblyAIKeySaved: Bool = false

    @State private var claudeKey: String = ""
    @State private var showClaudeKey: Bool = false
    @State private var claudeKeySaved: Bool = false

    // Tracks which key field is focused so we can auto-save when the keyboard dismisses.
    enum KeyField: Hashable { case assemblyAI, claude }
    @FocusState private var focusedField: KeyField?

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
            storageSection(t)
            providerSection(t)
            themeSection(t)
            aboutSection(t)
        }
        .scrollContentBackground(.hidden)
        .background(t.colors.backgroundPrimary)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .listStyle(.insetGrouped)
        .onAppear {
            assemblyAIKey     = KeychainService.retrieve(.assemblyAIAPIKey) ?? ""
            claudeKey         = KeychainService.retrieve(.anthropicAPIKey)  ?? ""
            assemblyAIKeySaved = !assemblyAIKey.isEmpty
            claudeKeySaved     = !claudeKey.isEmpty
        }
        .onChange(of: focusedField) { oldField, _ in
            // Auto-save whichever field just lost focus
            if oldField == .assemblyAI { saveAssemblyAIKey() }
            if oldField == .claude     { saveClaudeKey() }
        }
    }

    // MARK: - Recording Mode Section

    private func recordingModeSection(_ t: AppTheme) -> some View {
        Section {
            ForEach(RecordingMode.allCases) { mode in
                Button {
                    defaultModeRaw = mode.rawValue
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
                        }
                        Spacer()
                        if defaultModeRaw == mode.rawValue {
                            Image(systemName: "checkmark")
                                .foregroundStyle(t.colors.accentPrimary)
                                .font(.system(size: 14, weight: .semibold))
                        }
                    }
                    .padding(.vertical, t.spacing.xs)
                }
                .buttonStyle(PlainButtonStyle())
                .listRowBackground(t.colors.surfacePrimary)
            }
        } header: {
            sectionHeader("Default Recording Mode", t: t)
        } footer: {
            Text("Private keeps all processing on-device. Best Quality sends audio to AssemblyAI for speaker-labeled transcripts and structured notes — requires an AssemblyAI API key (see below).")
                .font(t.typography.caption)
                .foregroundStyle(t.colors.textTertiary)
        }
    }

    // MARK: - Best Quality / AssemblyAI Section

    private func bestQualitySection(_ t: AppTheme) -> some View {
        Section {
            apiKeyRow(
                label: "AssemblyAI API Key",
                placeholder: "Paste key…",
                key: $assemblyAIKey,
                show: $showAssemblyAIKey,
                saved: assemblyAIKeySaved,
                focusTag: KeyField.assemblyAI,
                onRemove: {
                    assemblyAIKey = ""
                    KeychainService.delete(.assemblyAIAPIKey)
                    assemblyAIKeySaved = false
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
            Text("AssemblyAI transcribes your meetings with speaker labels. Audio is sent to AssemblyAI for processing. Transcripts are stored locally on your device only.\n\nKey saved automatically when you leave the field. Get a free key at assemblyai.com.")
                .font(t.typography.caption)
                .foregroundStyle(t.colors.textTertiary)
        }
    }

    private func saveAssemblyAIKey() {
        let trimmed = assemblyAIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        assemblyAIKey = trimmed
        let ok = KeychainService.store(trimmed, for: .assemblyAIAPIKey)
        assemblyAIKeySaved = ok
        print("[Settings] AssemblyAI key save: \(ok ? "success" : "FAILED")")
    }

    // MARK: - Claude / Summary Section

    private func claudeSection(_ t: AppTheme) -> some View {
        Section {
            apiKeyRow(
                label: "Anthropic API Key",
                placeholder: "Paste key…",
                key: $claudeKey,
                show: $showClaudeKey,
                saved: claudeKeySaved,
                focusTag: KeyField.claude,
                onRemove: {
                    claudeKey = ""
                    KeychainService.delete(.anthropicAPIKey)
                    claudeKeySaved = false
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
            Text("Claude Sonnet generates structured meeting notes from the transcript. Only transcript text is sent to Anthropic — audio never leaves your device.\n\nAssemblyAI LeMUR is used automatically if no Claude key is set. Notes are stored locally only.\n\nKey saved automatically when you leave the field. Get a key at console.anthropic.com.")
                .font(t.typography.caption)
                .foregroundStyle(t.colors.textTertiary)
        }
    }

    private func saveClaudeKey() {
        let trimmed = claudeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        claudeKey = trimmed
        let ok = KeychainService.store(trimmed, for: .anthropicAPIKey)
        claudeKeySaved = ok
        print("[Settings] Claude key save: \(ok ? "success" : "FAILED")")
    }

    // MARK: - Shared API Key Row

    /// Full-width, 44pt-minimum key entry row. Saves automatically on Return or focus loss.
    @ViewBuilder
    private func apiKeyRow(
        label: String,
        placeholder: String,
        key: Binding<String>,
        show: Binding<Bool>,
        saved: Bool,
        focusTag: KeyField,
        onRemove: @escaping () -> Void,
        t: AppTheme
    ) -> some View {
        // Label + status/remove on one row
        HStack {
            Text(label)
                .font(t.typography.headlineSmall)
                .foregroundStyle(t.colors.textPrimary)
            Spacer()
            if saved {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(t.typography.caption)
                    .foregroundStyle(t.colors.accentSuccess)
            } else if !key.wrappedValue.isEmpty {
                Button("Remove") {
                    onRemove()
                    HapticStyle.light.trigger()
                }
                .font(t.typography.caption)
                .foregroundStyle(t.colors.accentError)
                .buttonStyle(PlainButtonStyle())
            }
        }
        .listRowBackground(t.colors.surfacePrimary)

        // Text field row — full width with a guaranteed 44pt tap target
        HStack(spacing: t.spacing.s) {
            Group {
                if show.wrappedValue {
                    TextField(placeholder, text: key)
                        .focused($focusedField, equals: focusTag)
                } else {
                    SecureField(placeholder, text: key)
                        .focused($focusedField, equals: focusTag)
                }
            }
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(t.colors.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .onSubmit {
                if focusTag == .assemblyAI { saveAssemblyAIKey() }
                if focusTag == .claude     { saveClaudeKey() }
            }

            Button {
                show.wrappedValue.toggle()
            } label: {
                Image(systemName: show.wrappedValue ? "eye.slash" : "eye")
                    .font(.system(size: 18))
                    .foregroundStyle(t.colors.textSecondary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .listRowBackground(t.colors.surfacePrimary)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 8))
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
                Text("Local only")
                    .font(t.typography.bodySmall)
                    .foregroundStyle(t.colors.textSecondary)
            }
            .listRowBackground(t.colors.surfacePrimary)

            HStack {
                Label("iCloud Sync", systemImage: "icloud")
                    .foregroundStyle(t.colors.textSecondary)
                Spacer()
                Text("Coming soon")
                    .font(t.typography.caption)
                    .foregroundStyle(t.colors.textTertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(t.colors.surfaceSecondary)
                    .clipShape(Capsule())
            }
            .listRowBackground(t.colors.surfacePrimary)
        } header: {
            sectionHeader("Storage", t: t)
        }
    }

    // MARK: - Provider Section

    private func providerSection(_ t: AppTheme) -> some View {
        Section {
            // Transcription
            Picker(selection: $transcriptionProviderRaw) {
                ForEach(TranscriptionProvider.allCases) { provider in
                    VStack(alignment: .leading) {
                        Text(provider.displayName)
                    }
                    .tag(provider.rawValue)
                }
            } label: {
                Label("Transcription", systemImage: "waveform.badge.mic")
                    .foregroundStyle(t.colors.textPrimary)
            }
            .tint(t.colors.accentPrimary)
            .listRowBackground(t.colors.surfacePrimary)

            if let provider = TranscriptionProvider(rawValue: transcriptionProviderRaw) {
                providerPrivacyRow(provider.privacyLabels, t: t)
            }

            // Summary
            Picker(selection: $summaryProviderRaw) {
                ForEach(SummaryProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider.rawValue)
                }
            } label: {
                Label("Summarization", systemImage: "sparkles")
                    .foregroundStyle(t.colors.textPrimary)
            }
            .tint(t.colors.accentPrimary)
            .listRowBackground(t.colors.surfacePrimary)

            if let provider = SummaryProvider(rawValue: summaryProviderRaw), provider.requiresApiKey {
                apiKeyNote(provider.displayName, t: t)
            }

        } header: {
            sectionHeader("AI Providers", t: t)
        } footer: {
            Text("Bring-your-own API key support is coming. Providers marked \"On-device\" never send data externally.")
                .font(t.typography.caption)
                .foregroundStyle(t.colors.textTertiary)
        }
    }

    private func providerPrivacyRow(_ labels: [String], t: AppTheme) -> some View {
        HStack(spacing: t.spacing.s) {
            ForEach(labels, id: \.self) { label in
                Text(label)
                    .font(t.typography.labelSmall)
                    .foregroundStyle(t.colors.accentSuccess)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(t.colors.accentSuccess.opacity(0.12))
                    .clipShape(Capsule())
            }
            Spacer()
        }
        .listRowBackground(t.colors.surfacePrimary)
    }

    private func apiKeyNote(_ providerName: String, t: AppTheme) -> some View {
        HStack(spacing: t.spacing.s) {
            Image(systemName: "key")
                .font(.system(size: 12))
                .foregroundStyle(t.colors.accentWarning)
            Text("\(providerName) requires an API key — BYOK coming soon")
                .font(t.typography.caption)
                .foregroundStyle(t.colors.accentWarning)
        }
        .listRowBackground(t.colors.accentWarning.opacity(0.08))
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

    // MARK: - Helpers

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
    .preferredColorScheme(.dark)
}
