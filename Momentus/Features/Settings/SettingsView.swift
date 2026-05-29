import SwiftUI

struct SettingsView: View {
    @Environment(ThemeManager.self) private var themeManager

    @AppStorage("defaultRecordingMode") private var defaultModeRaw: String = RecordingMode.onDevice.rawValue
    @AppStorage("audioRetention") private var audioRetentionRaw: String = AudioRetentionPolicy.deleteAfterTranscript.rawValue
    @AppStorage("transcriptionProvider") private var transcriptionProviderRaw: String = TranscriptionProvider.appleOnDevice.rawValue
    @AppStorage("summaryProvider") private var summaryProviderRaw: String = SummaryProvider.appleFoundationModels.rawValue
    @AppStorage("showConsentPrompt") private var showConsentPrompt: Bool = false
    @AppStorage("iCloudSync") private var iCloudSync: Bool = false

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
            Text("Private Mode keeps all processing on-device. Best Quality sends audio to your selected provider for higher accuracy.")
                .font(t.typography.caption)
                .foregroundStyle(t.colors.textTertiary)
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
