import SwiftUI

struct NotesListView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(RecordingsStore.self) private var store
    @State private var vm = NotesViewModel()
    @State private var selectedRecording: Recording?

    var body: some View {
        let t = themeManager.currentTheme
        let recordings = vm.filteredRecordings(from: store)

        ScrollView {
            LazyVStack(spacing: 0) {
                filterBar(t)
                    .padding(.vertical, t.spacing.m)

                if recordings.isEmpty {
                    emptyState(t)
                } else {
                    ForEach(recordings) { recording in
                        Button {
                            selectedRecording = recording
                        } label: {
                            RecordingCard(recording: recording)
                                .environment(themeManager)
                                .padding(.horizontal, t.spacing.l)
                                .padding(.vertical, t.spacing.xs)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .contextMenu {
                            Button(role: .destructive) {
                                store.delete(recording)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .padding(.bottom, t.spacing.hero + t.spacing.huge)
        }
        .background(t.colors.backgroundPrimary)
        .navigationTitle("Notes")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $vm.searchText, prompt: "Search meetings")
        .sheet(item: $selectedRecording) { recording in
            MeetingSummaryDetailView(recording: recording)
                .environment(themeManager)
                .environment(store)
        }
        .task {
            await store.importCloudRecordingsWithRetry()
        }
        .onReceive(NotificationCenter.default.publisher(for: .recordingProcessingCompleted)) { notification in
            guard let id = notification.userInfo?["recordingId"] as? UUID,
                  let recording = store.recording(for: id) else { return }
            selectedRecording = recording
        }
    }

    // MARK: - Filter Bar

    private func filterBar(_ t: AppTheme) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: t.spacing.s) {
                ForEach(RecordingFilter.allCases) { filter in
                    FilterChip(
                        label: filter.displayName,
                        isSelected: vm.selectedFilter == filter
                    ) {
                        vm.selectedFilter = filter
                        HapticStyle.light.trigger()
                    }
                    .environment(themeManager)
                }
            }
            .padding(.horizontal, t.spacing.l)
        }
    }

    // MARK: - Empty State

    private func emptyState(_ t: AppTheme) -> some View {
        VStack(spacing: t.spacing.l) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(t.colors.textTertiary)
                .padding(.top, t.spacing.huge)
            VStack(spacing: t.spacing.s) {
                Text(vm.searchText.isEmpty ? "No recordings" : "No results")
                    .font(t.typography.headlineMedium)
                    .foregroundStyle(t.colors.textSecondary)
                Text(vm.searchText.isEmpty
                    ? "Your processed meetings will appear here."
                    : "Try a different search or filter.")
                    .font(t.typography.bodySmall)
                    .foregroundStyle(t.colors.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(t.spacing.xxxl)
    }
}

// MARK: - Filter Chip

struct FilterChip: View {
    @Environment(ThemeManager.self) private var themeManager
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let t = themeManager.currentTheme
        Button(action: action) {
            Text(label)
                .font(t.typography.labelLarge)
                .foregroundStyle(isSelected ? t.colors.textOnAccent : t.colors.textSecondary)
                .padding(.horizontal, t.spacing.m)
                .padding(.vertical, t.spacing.s)
                .background(isSelected ? t.colors.accentPrimary : t.colors.surfacePrimary)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(
                    isSelected ? .clear : t.colors.border,
                    lineWidth: 0.5
                ))
        }
        .buttonStyle(PlainButtonStyle())
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

// MARK: - Recording Card

struct RecordingCard: View {
    @Environment(ThemeManager.self) private var themeManager
    let recording: Recording

    var body: some View {
        let t = themeManager.currentTheme
        VStack(alignment: .leading, spacing: t.spacing.m) {
            cardHeader(t)
            if let summary = recording.summary?.executiveSummary {
                Text(summary)
                    .font(t.typography.bodySmall)
                    .foregroundStyle(t.colors.textSecondary)
                    .lineLimit(2)
            }
            cardFooter(t)
        }
        .padding(t.spacing.l)
        .background(
            ZStack {
                t.colors.surfacePrimary
                t.gradients.cardAccent
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: t.radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: t.radius.card)
                .strokeBorder(t.colors.border, lineWidth: 0.5)
        )
        .shadow(color: t.shadows.card.color, radius: t.shadows.card.radius, x: t.shadows.card.x, y: t.shadows.card.y)
    }

    private func cardHeader(_ t: AppTheme) -> some View {
        HStack(alignment: .top, spacing: t.spacing.s) {
            VStack(alignment: .leading, spacing: 4) {
                Text(recording.title)
                    .font(t.typography.headlineMedium)
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
                    Text("·")
                        .foregroundStyle(t.colors.textTertiary)
                    Text(recording.startedAt.timeString())
                        .font(t.typography.caption)
                        .foregroundStyle(t.colors.textSecondary)
                }
            }
            Spacer()
            if recording.processingState != .completed {
                processingBadge(t)
            } else {
                ModeBadge(mode: recording.mode, compact: true)
                    .environment(themeManager)
            }
        }
    }

    private func cardFooter(_ t: AppTheme) -> some View {
        HStack(spacing: t.spacing.s) {
            if recording.actionItemCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.square")
                        .font(.system(size: 11))
                    Text("\(recording.actionItemCount) action\(recording.actionItemCount == 1 ? "" : "s")")
                        .font(t.typography.labelLarge)
                }
                .foregroundStyle(t.colors.accentPrimary.opacity(0.85))
            }
            if recording.isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(t.colors.accentWarning)
            }
            if recording.isLowConfidence {
                ConfidenceBadge(label: "Low confidence", isWarning: true)
                    .environment(themeManager)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(t.colors.textTertiary)
        }
    }

    private func processingBadge(_ t: AppTheme) -> some View {
        HStack(spacing: 4) {
            ProgressView()
                .scaleEffect(0.6)
                .tint(t.colors.accentPrimary)
            Text(recording.processingState.displayName)
                .font(t.typography.labelLarge)
                .foregroundStyle(t.colors.accentPrimary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(t.colors.accentPrimary.opacity(0.12))
        .clipShape(Capsule())
    }
}

#Preview {
    NavigationStack {
        NotesListView()
    }
    .environment(ThemeManager())
    .environment(RecordingsStore())
    .preferredColorScheme(.dark)
}
