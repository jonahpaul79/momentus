import SwiftUI

struct RecordHomeView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(RecordingsStore.self) private var store
    @State private var vm = RecordViewModel()
    @State private var showingActiveRecording = false
    @State private var showingProcessing = false
    var body: some View {
        let t = themeManager.currentTheme
        ScrollView {
            VStack(spacing: 0) {
                heroSection(t)
                controlsSection(t)
                if !vm.upcomingMeetings.isEmpty {
                    upNextSection(t)
                }
            }
            .padding(.bottom, t.spacing.hero + t.spacing.huge)
        }
        .background(t.gradients.heroBackground)
        .task {
            vm.configure(store: store)
            vm.configure(
                transcriptionService: ServiceFactory.makeTranscriptionService(for: vm.selectedMode),
                summaryService: ServiceFactory.makeSummaryService(for: vm.selectedMode)
            )
            await vm.loadCalendarContext()
        }
        .onChange(of: vm.selectedMode) { _, newMode in
            vm.configure(
                transcriptionService: ServiceFactory.makeTranscriptionService(for: newMode),
                summaryService: ServiceFactory.makeSummaryService(for: newMode)
            )
        }
        .fullScreenCover(isPresented: $showingActiveRecording) {
            ActiveRecordingView(vm: vm, onStop: {
                showingActiveRecording = false
                showingProcessing = true
            })
            .environment(themeManager)
        }
        .fullScreenCover(isPresented: $showingProcessing) {
            ProcessingView(vm: vm, onDismiss: {
                showingProcessing = false
            })
            .environment(themeManager)
        }
        .onChange(of: vm.state) { _, newState in
            switch newState {
            case .recording:
                showingActiveRecording = true
            case .completed:
                showingProcessing = false
            default:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .autoStartRecording)) { _ in
            guard vm.state == .idle else { return }
            Task { await vm.startRecording() }
        }
    }

    // MARK: - Hero Section

    private func heroSection(_ t: AppTheme) -> some View {
        VStack(spacing: t.spacing.l) {
            modePill(t)
                .padding(.top, t.spacing.hero + t.spacing.xl)

            // Record Button
            Button {
                HapticStyle.medium.trigger()
                Task { await vm.startRecording() }
            } label: {
                ZStack {
                    Circle()
                        .fill(t.gradients.heroBackground)
                        .frame(width: 148, height: 148)
                        .overlay(
                            Circle()
                                .strokeBorder(t.colors.accentPrimary.opacity(0.3), lineWidth: 1)
                        )

                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [t.colors.accentPrimary, t.colors.accentPrimary.opacity(0.75)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 110, height: 110)
                        .shadow(color: t.colors.accentPrimary.opacity(0.45), radius: 24, x: 0, y: 0)

                    VStack(spacing: 4) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 30, weight: .medium))
                            .foregroundStyle(.white)
                        Text("Record")
                            .font(t.typography.labelLarge)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
            .buttonStyle(PlainButtonStyle())

            micSourcePicker(t)
        }
        .padding(.horizontal, t.spacing.l)
        .padding(.bottom, t.spacing.xl)
    }

    // MARK: - Mode Pill

    private func modePill(_ t: AppTheme) -> some View {
        Menu {
            ForEach(RecordingMode.allCases) { mode in
                Button {
                    vm.selectedMode = mode
                    HapticStyle.light.trigger()
                } label: {
                    HStack {
                        Image(systemName: mode.icon)
                        Text(mode.displayName)
                        if vm.selectedMode == mode {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: vm.selectedMode.icon)
                    .font(.system(size: 12, weight: .medium))
                Text(vm.selectedMode.displayName)
                    .font(t.typography.labelLarge)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(t.colors.textPrimary)
            .padding(.horizontal, t.spacing.m)
            .padding(.vertical, t.spacing.s)
            .background(t.colors.surfaceSecondary)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(t.colors.border, lineWidth: 0.5))
        }
    }

    // MARK: - Mic Source Picker

    private func micSourcePicker(_ t: AppTheme) -> some View {
        HStack(spacing: t.spacing.s) {
            ForEach(MicSource.allCases) { source in
                Button {
                    vm.selectedMicSource = source
                    HapticStyle.light.trigger()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: source.icon)
                            .font(.system(size: 12))
                        Text(source.shortName)
                            .font(t.typography.labelLarge)
                    }
                    .foregroundStyle(vm.selectedMicSource == source ? t.colors.textPrimary : t.colors.textSecondary)
                    .padding(.horizontal, t.spacing.m)
                    .padding(.vertical, t.spacing.s)
                    .background(vm.selectedMicSource == source ? t.colors.surfaceSecondary : Color.clear)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule().strokeBorder(
                            vm.selectedMicSource == source ? t.colors.borderStrong : t.colors.border,
                            lineWidth: 0.5
                        )
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    // MARK: - Controls Section

    private func controlsSection(_ t: AppTheme) -> some View {
        VStack(spacing: t.spacing.s) {
            HStack(spacing: t.spacing.xs) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(t.colors.accentSuccess)
                Text(vm.selectedMode.privacyLabel)
                    .font(t.typography.labelMedium)
                    .foregroundStyle(t.colors.textSecondary)
            }

            if vm.isMissingTranscriptionKey {
                HStack(spacing: t.spacing.xs) {
                    Image(systemName: "key.slash")
                        .font(.system(size: 11))
                        .foregroundStyle(t.colors.accentWarning)
                    Text("AssemblyAI key missing — add it in Settings for Best Quality")
                        .font(t.typography.caption)
                        .foregroundStyle(t.colors.accentWarning)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if vm.isUsingSummaryFallback {
                HStack(spacing: t.spacing.xs) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(t.colors.textTertiary)
                    Text("Claude key missing — summary will use AssemblyAI LeMUR")
                        .font(t.typography.caption)
                        .foregroundStyle(t.colors.textTertiary)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, t.spacing.l)
        .animation(.easeInOut(duration: 0.2), value: vm.isMissingTranscriptionKey)
        .animation(.easeInOut(duration: 0.2), value: vm.isUsingSummaryFallback)
    }

    // MARK: - Up Next

    private func upNextSection(_ t: AppTheme) -> some View {
        VStack(alignment: .leading, spacing: t.spacing.m) {
            Text("Up Next")
                .font(t.typography.headlineMedium)
                .foregroundStyle(t.colors.textPrimary)
                .padding(.horizontal, t.spacing.l)
                .padding(.top, t.spacing.xxl)

            VStack(spacing: 0) {
                ForEach(Array(vm.upcomingMeetings.enumerated()), id: \.element.id) { index, meeting in
                    Button {
                        vm.suggestedMeetingTitle = meeting.title
                        vm.suggestedSpeakers = meeting.attendees
                        if meeting.isHappeningNow {
                            HapticStyle.medium.trigger()
                            Task { await vm.startRecording() }
                        } else {
                            HapticStyle.light.trigger()
                        }
                    } label: {
                        upNextRow(meeting, t: t)
                    }
                    .buttonStyle(.plain)

                    if index < vm.upcomingMeetings.count - 1 {
                        Divider()
                            .padding(.leading, t.spacing.l)
                    }
                }
            }
            .surfaceCard()
            .environment(themeManager)
            .padding(.horizontal, t.spacing.l)
        }
    }

    private func upNextRow(_ meeting: CalendarMeeting, t: AppTheme) -> some View {
        HStack(spacing: t.spacing.m) {
            VStack(alignment: .leading, spacing: 5) {
                Text(meeting.title)
                    .font(t.typography.headlineSmall)
                    .foregroundStyle(t.colors.textPrimary)
                    .lineLimit(1)
                HStack(spacing: t.spacing.xs) {
                    Circle()
                        .fill(meeting.isHappeningNow ? t.colors.accentRecording : t.colors.accentWarning)
                        .frame(width: 6, height: 6)
                    Text(meetingTimeLabel(meeting))
                        .font(t.typography.caption)
                        .foregroundStyle(meeting.isHappeningNow ? t.colors.accentRecording : t.colors.textSecondary)
                    if !meeting.attendees.isEmpty {
                        Text("·")
                            .foregroundStyle(t.colors.textTertiary)
                        Text("\(meeting.attendees.count) people")
                            .font(t.typography.caption)
                            .foregroundStyle(t.colors.textTertiary)
                    }
                }
            }
            Spacer()
            if vm.suggestedMeetingTitle == meeting.title {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(t.colors.accentPrimary)
            } else {
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(t.colors.textTertiary)
            }
        }
        .padding(t.spacing.l)
        .contentShape(Rectangle())
    }

    private func meetingTimeLabel(_ meeting: CalendarMeeting) -> String {
        if meeting.isHappeningNow { return "Happening now" }
        let minutes = Int(meeting.startDate.timeIntervalSinceNow / 60)
        if minutes < 60 { return "in \(minutes)m" }
        let hours = minutes / 60
        let rem = minutes % 60
        return rem == 0 ? "in \(hours)h" : "in \(hours)h \(rem)m"
    }
}


#Preview {
    NavigationStack {
        RecordHomeView()
    }
    .environment(ThemeManager())
    .environment(RecordingsStore())
    .preferredColorScheme(.dark)
}
