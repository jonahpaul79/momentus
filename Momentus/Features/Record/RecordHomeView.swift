import SwiftUI

struct RecordHomeView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(RecordingsStore.self) private var store
    @State private var vm = RecordViewModel()
    @State private var showingActiveRecording = false
    @State private var showingProcessing = false
    @State private var selectedRecording: Recording?

    var body: some View {
        let t = themeManager.currentTheme
        ScrollView {
            VStack(spacing: 0) {
                heroSection(t)
                controlsSection(t)
                if let meeting = vm.calendarMeeting {
                    calendarCard(meeting, t: t)
                        .padding(.horizontal, t.spacing.l)
                        .padding(.top, t.spacing.l)
                } else {
                    howItWorksCard(t)
                        .padding(.horizontal, t.spacing.l)
                        .padding(.top, t.spacing.l)
                }
                recentSection(t)
            }
            .padding(.bottom, t.spacing.huge)
        }
        .background(t.gradients.heroBackground)
        .navigationTitle("Momentus")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(t.colors.backgroundPrimary.opacity(0.95), for: .navigationBar)
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
        .sheet(item: $selectedRecording) { recording in
            MeetingSummaryDetailView(recording: recording)
                .environment(themeManager)
                .environment(store)
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
    }

    // MARK: - Hero Section

    private func heroSection(_ t: AppTheme) -> some View {
        VStack(spacing: t.spacing.l) {
            modePill(t)
                .padding(.top, t.spacing.xxl)

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

    // MARK: - How It Works

    private func howItWorksCard(_ t: AppTheme) -> some View {
        HStack(spacing: t.spacing.m) {
            VStack(alignment: .leading, spacing: t.spacing.xs) {
                Text("How Momentus works")
                    .font(t.typography.labelLarge)
                    .foregroundStyle(t.colors.textSecondary)
                Text("Tap Record, then just talk. Momentus transcribes your meeting and writes the summary for you.")
                    .font(t.typography.bodySmall)
                    .foregroundStyle(t.colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "sparkles")
                .font(.system(size: 20))
                .foregroundStyle(t.colors.accentPrimary.opacity(0.5))
        }
        .padding(t.spacing.l)
        .surfaceCard()
        .environment(themeManager)
    }

    // MARK: - Calendar Card

    private func calendarCard(_ meeting: CalendarMeeting, t: AppTheme) -> some View {
        Button {
            vm.suggestedMeetingTitle = meeting.title
            HapticStyle.light.trigger()
        } label: {
            HStack(spacing: t.spacing.m) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(meeting.isHappeningNow ? t.colors.accentRecording : t.colors.accentWarning)
                            .frame(width: 6, height: 6)
                        Text(meeting.isHappeningNow ? "Happening now" : "Starting soon")
                            .font(t.typography.labelMedium)
                            .foregroundStyle(meeting.isHappeningNow ? t.colors.accentRecording : t.colors.accentWarning)
                    }
                    Text(meeting.title)
                        .font(t.typography.headlineSmall)
                        .foregroundStyle(t.colors.textPrimary)
                        .lineLimit(1)
                    Text("Use as title?")
                        .font(t.typography.caption)
                        .foregroundStyle(t.colors.textSecondary)
                }
                Spacer()
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(t.colors.accentPrimary.opacity(0.8))
            }
            .padding(t.spacing.l)
            .surfaceCard()
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - Recent Recordings

    private func recentSection(_ t: AppTheme) -> some View {
        VStack(alignment: .leading, spacing: t.spacing.m) {
            Text("Recent")
                .font(t.typography.headlineMedium)
                .foregroundStyle(t.colors.textPrimary)
                .padding(.horizontal, t.spacing.l)
                .padding(.top, t.spacing.xxl)

            let completed = store.recordings.filter { $0.processingState == .completed }
            if completed.isEmpty {
                emptyRecentState(t)
            } else {
                ForEach(Array(completed.prefix(3))) { recording in
                    RecentRecordingRow(recording: recording)
                        .padding(.horizontal, t.spacing.l)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedRecording = recording }
                        .environment(themeManager)
                }
            }
        }
    }

    private func emptyRecentState(_ t: AppTheme) -> some View {
        VStack(spacing: t.spacing.m) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 36))
                .foregroundStyle(t.colors.textTertiary)
            Text("No recordings yet")
                .font(t.typography.bodyMedium)
                .foregroundStyle(t.colors.textSecondary)
            Text("Tap the button above to start your first recording.")
                .font(t.typography.bodySmall)
                .foregroundStyle(t.colors.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(t.spacing.xxxl)
    }
}

// MARK: - Recent Recording Row

struct RecentRecordingRow: View {
    @Environment(ThemeManager.self) private var themeManager
    let recording: Recording

    var body: some View {
        let t = themeManager.currentTheme
        HStack(spacing: t.spacing.m) {
            RoundedRectangle(cornerRadius: 3)
                .fill(modeColor(t))
                .frame(width: 3, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(recording.title)
                    .font(t.typography.headlineSmall)
                    .foregroundStyle(t.colors.textPrimary)
                    .lineLimit(1)
                HStack(spacing: t.spacing.s) {
                    Text(recording.startedAt.relativeLabel())
                        .font(t.typography.caption)
                        .foregroundStyle(t.colors.textSecondary)
                    Text("·")
                        .foregroundStyle(t.colors.textTertiary)
                    Text(recording.duration.shortString)
                        .font(t.typography.caption)
                        .foregroundStyle(t.colors.textSecondary)
                    if recording.actionItemCount > 0 {
                        Text("·")
                            .foregroundStyle(t.colors.textTertiary)
                        Text("\(recording.actionItemCount) actions")
                            .font(t.typography.caption)
                            .foregroundStyle(t.colors.accentPrimary.opacity(0.8))
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(t.colors.textTertiary)
        }
        .padding(.vertical, t.spacing.s)
    }

    private func modeColor(_ t: AppTheme) -> Color {
        switch recording.mode {
        case .onDevice: return t.colors.accentSuccess
        case .bestQuality: return t.colors.accentPrimary
        case .hybrid: return t.colors.accentSecondary
        }
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
