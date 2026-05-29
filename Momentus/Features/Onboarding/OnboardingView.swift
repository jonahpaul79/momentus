import SwiftUI
import AVFoundation
import Speech
import EventKit
import UserNotifications

struct OnboardingView: View {
    @Environment(ThemeManager.self) private var themeManager
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("defaultRecordingMode") private var defaultModeRaw: String = RecordingMode.onDevice.rawValue

    @State private var currentPage = 0
    @State private var micGranted = false
    @State private var speechGranted = false
    @State private var calendarGranted = false
    @State private var notificationsGranted = false

    private let totalPages = 5

    var body: some View {
        let t = themeManager.currentTheme
        ZStack {
            t.colors.backgroundPrimary.ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $currentPage) {
                    introPage1(t).tag(0)
                    introPage2(t).tag(1)
                    introPage3(t).tag(2)
                    permissionsPage(t).tag(3)
                    defaultModePage(t).tag(4)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut, value: currentPage)

                bottomNav(t)
            }
        }
    }

    // MARK: - Pages

    private func introPage1(_ t: AppTheme) -> some View {
        OnboardingPage(
            icon: "applewatch.radiowaves.left.and.right",
            iconColor: t.colors.accentPrimary,
            title: "Capture real-world meetings from your Watch",
            message: "One tap on your Apple Watch starts recording. Use your iPhone mic for the best audio quality — or go Watch-only when your phone isn't nearby.",
            accentGradient: t.gradients.heroBackground
        )
        .environment(themeManager)
    }

    private func introPage2(_ t: AppTheme) -> some View {
        OnboardingPage(
            icon: "lock.shield.fill",
            iconColor: t.colors.accentSuccess,
            title: "Private by default",
            message: "Private Mode keeps transcription and summaries on-device. No audio leaves your phone unless you choose Best Quality mode.",
            accentGradient: t.gradients.heroBackground
        )
        .environment(themeManager)
    }

    private func introPage3(_ t: AppTheme) -> some View {
        OnboardingPage(
            icon: "sparkles",
            iconColor: t.colors.accentSecondary,
            title: "Use Best Quality when accuracy matters",
            message: "Best Quality mode sends audio to your chosen provider for better transcription accuracy and richer AI-generated summaries.",
            accentGradient: t.gradients.heroBackground
        )
        .environment(themeManager)
    }

    private func permissionsPage(_ t: AppTheme) -> some View {
        ScrollView {
            VStack(spacing: t.spacing.xxxl) {
                VStack(spacing: t.spacing.m) {
                    iconCircle(systemName: "hand.raised.fill", color: t.colors.accentPrimary, t: t)
                        .padding(.top, t.spacing.huge)

                    Text("A few permissions")
                        .font(t.typography.displayMedium)
                        .foregroundStyle(t.colors.textPrimary)
                        .multilineTextAlignment(.center)

                    Text("Momentus needs these to work well. You can change them later in Settings.")
                        .font(t.typography.bodyMedium)
                        .foregroundStyle(t.colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, t.spacing.xxxl)
                }

                VStack(spacing: t.spacing.m) {
                    PermissionRow(
                        icon: "mic.fill",
                        title: "Microphone",
                        description: "Required for recording meetings",
                        isGranted: micGranted,
                        color: t.colors.accentPrimary
                    ) {
                        Task {
                            let granted = await AVAudioApplication.requestRecordPermission()
                            micGranted = granted
                            if granted { HapticStyle.success.trigger() }
                        }
                    }
                    .environment(themeManager)

                    PermissionRow(
                        icon: "waveform",
                        title: "Speech Recognition",
                        description: "Transcribes your meetings on-device",
                        isGranted: speechGranted,
                        color: t.colors.accentSecondary
                    ) {
                        Task {
                            let status = await withCheckedContinuation { cont in
                                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
                            }
                            speechGranted = status == .authorized
                            if speechGranted { HapticStyle.success.trigger() }
                        }
                    }
                    .environment(themeManager)

                    PermissionRow(
                        icon: "calendar",
                        title: "Calendar",
                        description: "Suggests meeting titles from your schedule",
                        isGranted: calendarGranted,
                        color: t.colors.accentSuccess
                    ) {
                        Task {
                            do {
                                let granted = try await EKEventStore().requestFullAccessToEvents()
                                calendarGranted = granted
                                if granted { HapticStyle.success.trigger() }
                            } catch {
                                calendarGranted = false
                            }
                        }
                    }
                    .environment(themeManager)

                    PermissionRow(
                        icon: "bell.fill",
                        title: "Notifications",
                        description: "Notifies you when processing is complete",
                        isGranted: notificationsGranted,
                        color: t.colors.accentWarning
                    ) {
                        Task {
                            do {
                                let granted = try await UNUserNotificationCenter.current()
                                    .requestAuthorization(options: [.alert, .sound, .badge])
                                notificationsGranted = granted
                                if granted { HapticStyle.success.trigger() }
                            } catch {
                                notificationsGranted = false
                            }
                        }
                    }
                    .environment(themeManager)
                }
                .padding(.horizontal, t.spacing.l)

                Spacer(minLength: t.spacing.huge)
            }
        }
        .task { await refreshPermissionStatuses() }
    }

    private func defaultModePage(_ t: AppTheme) -> some View {
        ScrollView {
            VStack(spacing: t.spacing.xxxl) {
                VStack(spacing: t.spacing.m) {
                    iconCircle(systemName: "slider.horizontal.3", color: t.colors.accentPrimary, t: t)
                        .padding(.top, t.spacing.huge)

                    Text("Choose your default mode")
                        .font(t.typography.displayMedium)
                        .foregroundStyle(t.colors.textPrimary)
                        .multilineTextAlignment(.center)

                    Text("You can change this anytime in Settings.")
                        .font(t.typography.bodyMedium)
                        .foregroundStyle(t.colors.textSecondary)
                }
                .padding(.horizontal, t.spacing.l)

                VStack(spacing: t.spacing.m) {
                    ForEach(RecordingMode.allCases) { mode in
                        ModeSelectionCard(
                            mode: mode,
                            isSelected: defaultModeRaw == mode.rawValue
                        ) {
                            defaultModeRaw = mode.rawValue
                            HapticStyle.light.trigger()
                        }
                        .environment(themeManager)
                    }
                }
                .padding(.horizontal, t.spacing.l)

                Spacer(minLength: 120)
            }
        }
    }

    // MARK: - Permission Status Check

    private func refreshPermissionStatuses() async {
        micGranted = AVAudioApplication.shared.recordPermission == .granted


        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        speechGranted = speechStatus == .authorized

        let calStatus = EKEventStore.authorizationStatus(for: .event)
        calendarGranted = calStatus == .fullAccess

        let notifSettings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsGranted = notifSettings.authorizationStatus == .authorized
    }

    // MARK: - Bottom Navigation

    private func bottomNav(_ t: AppTheme) -> some View {
        VStack(spacing: t.spacing.l) {
            HStack(spacing: 6) {
                ForEach(0..<totalPages, id: \.self) { i in
                    Capsule()
                        .fill(i == currentPage ? t.colors.accentPrimary : t.colors.surfaceSecondary)
                        .frame(width: i == currentPage ? 20 : 6, height: 6)
                        .animation(.easeInOut(duration: 0.2), value: currentPage)
                }
            }

            Button {
                if currentPage < totalPages - 1 {
                    withAnimation { currentPage += 1 }
                } else {
                    HapticStyle.success.trigger()
                    hasCompletedOnboarding = true
                }
            } label: {
                Text(currentPage < totalPages - 1 ? "Continue" : "Get started")
                    .font(t.typography.headlineMedium)
                    .foregroundStyle(t.colors.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, t.spacing.l)
                    .background(t.colors.accentPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: t.radius.l))
            }
            .padding(.horizontal, t.spacing.xxxl)

            if currentPage < totalPages - 1 {
                Button("Skip") {
                    HapticStyle.light.trigger()
                    hasCompletedOnboarding = true
                }
                .font(t.typography.bodySmall)
                .foregroundStyle(t.colors.textTertiary)
            }
        }
        .padding(.vertical, t.spacing.l)
        .padding(.bottom, t.spacing.l)
    }

    // MARK: - Helpers

    private func iconCircle(systemName: String, color: Color, t: AppTheme) -> some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.14))
                .frame(width: 88, height: 88)
            Image(systemName: systemName)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(color)
        }
    }
}

// MARK: - Onboarding Page

struct OnboardingPage: View {
    @Environment(ThemeManager.self) private var themeManager
    let icon: String
    let iconColor: Color
    let title: String
    let message: String
    let accentGradient: LinearGradient

    var body: some View {
        let t = themeManager.currentTheme
        VStack(spacing: t.spacing.xxl) {
            Spacer()
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.14))
                    .frame(width: 100, height: 100)
                Image(systemName: icon)
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(iconColor)
            }
            VStack(spacing: t.spacing.l) {
                Text(title)
                    .font(t.typography.displayMedium)
                    .foregroundStyle(t.colors.textPrimary)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(t.typography.bodyLarge)
                    .foregroundStyle(t.colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            .padding(.horizontal, t.spacing.xxxl)
            Spacer()
            Spacer()
        }
    }
}

// MARK: - Permission Row

struct PermissionRow: View {
    @Environment(ThemeManager.self) private var themeManager
    let icon: String
    let title: String
    let description: String
    let isGranted: Bool
    let color: Color
    let onGrant: () -> Void

    var body: some View {
        let t = themeManager.currentTheme
        HStack(spacing: t.spacing.m) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(color.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(color)
            }
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
                    .font(.system(size: 22))
            } else {
                Button("Allow") { onGrant() }
                    .font(t.typography.labelLarge)
                    .foregroundStyle(t.colors.textOnAccent)
                    .padding(.horizontal, t.spacing.m)
                    .padding(.vertical, t.spacing.s)
                    .background(color)
                    .clipShape(Capsule())
            }
        }
        .padding(t.spacing.l)
        .surfaceCard()
        .environment(themeManager)
    }
}

// MARK: - Mode Selection Card

struct ModeSelectionCard: View {
    @Environment(ThemeManager.self) private var themeManager
    let mode: RecordingMode
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        let t = themeManager.currentTheme
        Button(action: onSelect) {
            HStack(spacing: t.spacing.m) {
                ZStack {
                    Circle()
                        .fill(modeColor(t).opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: mode.icon)
                        .font(.system(size: 18))
                        .foregroundStyle(modeColor(t))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.displayName)
                        .font(t.typography.headlineSmall)
                        .foregroundStyle(t.colors.textPrimary)
                    Text(mode.description)
                        .font(t.typography.caption)
                        .foregroundStyle(t.colors.textSecondary)
                    Text(mode.privacyLabel)
                        .font(t.typography.labelSmall)
                        .foregroundStyle(modeColor(t).opacity(0.8))
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(t.colors.accentPrimary)
                } else {
                    Circle()
                        .strokeBorder(t.colors.border, lineWidth: 1.5)
                        .frame(width: 22, height: 22)
                }
            }
            .padding(t.spacing.l)
            .background(isSelected ? modeColor(t).opacity(0.08) : t.colors.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: t.radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: t.radius.card)
                    .strokeBorder(isSelected ? modeColor(t).opacity(0.4) : t.colors.border, lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }

    private func modeColor(_ t: AppTheme) -> Color {
        switch mode {
        case .onDevice: return t.colors.accentSuccess
        case .bestQuality: return t.colors.accentPrimary
        case .hybrid: return t.colors.accentSecondary
        }
    }
}

#Preview {
    OnboardingView()
        .environment(ThemeManager())
        .preferredColorScheme(.dark)
}
