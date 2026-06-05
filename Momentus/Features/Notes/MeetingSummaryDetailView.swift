import AVFoundation
import SwiftUI

struct MeetingSummaryDetailView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(RecordingsStore.self) private var store
    @State var recording: Recording
    @State private var showingTranscript = false
    @State private var showShareSheet = false
    @State private var exportedText = ""
    @State private var playbackSeekTime: TimeInterval?
    @State private var speakerAssignments: [UUID: String] = [:]
    @Environment(\.dismiss) private var dismiss
    @AppStorage("audioRetention") private var audioRetentionRaw: String = AudioRetentionPolicy.deleteAfterTranscript.rawValue

    private var hasAudio: Bool {
        guard recording.audioFileID != nil else { return false }
        let policy = AudioRetentionPolicy(rawValue: audioRetentionRaw) ?? .deleteAfterTranscript
        return policy != .deleteAfterTranscript
    }

    var body: some View {
        let t = themeManager.currentTheme
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    meetingHeader(t)
                    if let summary = recording.summary {
                        summaryContent(summary, t: t)
                    } else {
                        noSummaryState(t)
                    }
                }
                .padding(.bottom, t.spacing.huge)
            }
            .background(t.colors.backgroundPrimary)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(t.colors.textSecondary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { copyToClipboard() } label: {
                            Label("Copy summary", systemImage: "doc.on.doc")
                        }
                        Button { exportMarkdown() } label: {
                            Label("Export Markdown", systemImage: "arrow.up.doc")
                        }
                        Button { store.toggle(favorite: recording.id) } label: {
                            Label(
                                recording.isFavorite ? "Remove favorite" : "Add to favorites",
                                systemImage: recording.isFavorite ? "star.slash" : "star"
                            )
                        }
                        Divider()
                        Button(role: .destructive) { store.delete(recording); dismiss() } label: {
                            Label("Delete recording", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(t.colors.textSecondary)
                    }
                }
            }
            .sheet(isPresented: $showingTranscript) {
                if let transcript = recording.transcript {
                    TranscriptDetailView(transcript: transcript, recordingTitle: recording.title)
                        .environment(themeManager)
                }
            }
            .sheet(isPresented: $showShareSheet) {
                ShareSheet(text: exportedText)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            if let updated = store.recording(for: recording.id) { recording = updated }
        }
    }

    // MARK: - Header

    private func meetingHeader(_ t: AppTheme) -> some View {
        VStack(alignment: .leading, spacing: t.spacing.m) {
            Text(recording.title)
                .font(t.typography.displayMedium)
                .foregroundStyle(t.colors.textPrimary)

            HStack(spacing: t.spacing.m) {
                Label(recording.startedAt.relativeLabel(), systemImage: "calendar")
                    .font(t.typography.bodySmall)
                    .foregroundStyle(t.colors.textSecondary)
                Label(recording.duration.shortString, systemImage: "clock")
                    .font(t.typography.bodySmall)
                    .foregroundStyle(t.colors.textSecondary)
                ModeBadge(mode: recording.mode, compact: true)
                    .environment(themeManager)
            }

            if hasAudio, let audioFileID = recording.audioFileID {
                AudioPlayerView(
                    seed: recording.id.hashValue,
                    duration: recording.duration,
                    audioFileID: audioFileID,
                    seekTime: $playbackSeekTime
                )
                    .environment(themeManager)
            }
        }
        .padding(t.spacing.l)
        .padding(.top, t.spacing.m)
    }

    // MARK: - Summary Content

    private func summaryContent(_ summary: MeetingSummary, t: AppTheme) -> some View {
        VStack(alignment: .leading, spacing: t.spacing.l) {
            if let attendees = recording.calendarAttendees,
               !attendees.isEmpty,
               let speakers = recording.transcript?.speakers.filter(\.isNameInferred),
               !speakers.isEmpty {
                speakerIdentificationCard(speakers: speakers, attendees: attendees, t: t)
            }
            executiveSummaryCard(summary, t: t)
            if !summary.markedMoments.isEmpty { markedMomentsSection(summary.markedMoments, t: t) }
            if !summary.decisions.isEmpty { decisionsSection(summary.decisions, t: t) }
            if !summary.actionItems.isEmpty { actionItemsSection(summary.actionItems, t: t) }
            if !summary.openQuestions.isEmpty { openQuestionsSection(summary.openQuestions, t: t) }
            if !summary.risks.isEmpty { risksSection(summary.risks, t: t) }
            if !summary.followUpDraft.isEmpty { followUpSection(summary.followUpDraft, t: t) }
            if recording.transcript != nil { transcriptButton(t) }
            if !summary.confidenceNotes.isEmpty { confidenceNotesSection(summary.confidenceNotes, t: t) }
            providerProvenanceView(summary, t: t)
        }
        .padding(.horizontal, t.spacing.l)
    }

    // MARK: - Marked Moments

    private func markedMomentsSection(_ moments: [MarkedMoment], t: AppTheme) -> some View {
        VStack(alignment: .leading, spacing: t.spacing.m) {
            sectionHeader("Marked Moments", icon: "bookmark.fill", t: t)
            ForEach(moments) { moment in
                Button {
                    playbackSeekTime = moment.timestamp
                    HapticStyle.light.trigger()
                } label: {
                    HStack(alignment: .top, spacing: t.spacing.m) {
                        Text(formatTimestamp(moment.timestamp))
                            .font(t.typography.labelSmall)
                            .foregroundStyle(t.colors.accentPrimary)
                            .monospacedDigit()
                            .frame(width: 46, alignment: .leading)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(moment.summary)
                                .font(t.typography.bodyMedium)
                                .foregroundStyle(t.colors.textPrimary)
                                .multilineTextAlignment(.leading)
                            if let excerpt = moment.transcriptExcerpt, !excerpt.isEmpty {
                                Text(excerpt)
                                    .font(t.typography.caption)
                                    .foregroundStyle(t.colors.textSecondary)
                                    .lineLimit(3)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        Spacer(minLength: 0)
                        if hasAudio {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(t.colors.accentPrimary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(!hasAudio)

                if moment.id != moments.last?.id {
                    Divider().overlay(t.colors.divider)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(t.spacing.l)
        .surfaceCard()
        .environment(themeManager)
    }

    // MARK: - Provider Provenance

    private func providerProvenanceView(_ summary: MeetingSummary, t: AppTheme) -> some View {
        let transcriptProvider = recording.transcript?.provider
        let summaryProvider = summary.provider
        return VStack(alignment: .center, spacing: t.spacing.xs) {
            HStack(spacing: t.spacing.s) {
                if let tp = transcriptProvider {
                    providerChip("Transcript", value: tp, t: t)
                    Text("·")
                        .font(t.typography.caption)
                        .foregroundStyle(t.colors.textTertiary)
                }
                providerChip("Notes", value: summaryProvider, t: t)
            }
            Text(processingDisclosure(transcriptProvider: transcriptProvider, summaryProvider: summaryProvider))
                .font(t.typography.caption)
                .foregroundStyle(t.colors.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, t.spacing.l)
        .padding(.bottom, t.spacing.m)
    }

    private func processingDisclosure(transcriptProvider: String?, summaryProvider: String) -> String {
        let usedCloudTranscription = transcriptProvider == "AssemblyAI"
        let usedCloudSummary = summaryProvider.contains("Claude") || summaryProvider.contains("AssemblyAI")

        switch (usedCloudTranscription, usedCloudSummary) {
        case (true, true):
            return "Audio sent to AssemblyAI for transcript. Transcript text sent for notes. Saved locally."
        case (true, false):
            return "Audio sent to AssemblyAI for transcript. Notes generated locally from transcript. Saved locally."
        case (false, true):
            return "Audio stayed on device. Transcript text sent for notes. Saved locally."
        case (false, false):
            return "Processed on device. Saved locally."
        }
    }

    private func providerChip(_ label: String, value: String, t: AppTheme) -> some View {
        VStack(alignment: .center, spacing: 1) {
            Text(label.uppercased())
                .font(t.typography.caption)
                .foregroundStyle(t.colors.textTertiary)
                .tracking(0.5)
            Text(value)
                .font(t.typography.labelSmall)
                .foregroundStyle(t.colors.textSecondary)
        }
    }

    // MARK: - Speaker Identification

    private func speakerIdentificationCard(speakers: [Speaker], attendees: [String], t: AppTheme) -> some View {
        VStack(alignment: .leading, spacing: t.spacing.m) {
            HStack(spacing: t.spacing.s) {
                Image(systemName: "person.2.wave.2")
                    .font(.system(size: 13))
                    .foregroundStyle(t.colors.accentPrimary)
                Text("IDENTIFY SPEAKERS")
                    .font(t.typography.labelLarge)
                    .foregroundStyle(t.colors.textSecondary)
                    .tracking(0.6)
                Spacer()
                Button("Apply") {
                    applySpeakerAssignments()
                }
                .font(t.typography.labelLarge)
                .foregroundStyle(speakerAssignments.isEmpty ? t.colors.textTertiary : t.colors.accentPrimary)
                .disabled(speakerAssignments.isEmpty)
            }

            Text("Match each unidentified voice to someone from the invite.")
                .font(t.typography.bodySmall)
                .foregroundStyle(t.colors.textSecondary)

            VStack(spacing: 0) {
                ForEach(Array(speakers.enumerated()), id: \.element.id) { index, speaker in
                    HStack {
                        Text(speaker.name)
                            .font(t.typography.bodyMedium)
                            .foregroundStyle(t.colors.textPrimary)
                        Spacer()
                        Menu {
                            ForEach(attendees, id: \.self) { attendee in
                                Button(attendee) {
                                    speakerAssignments[speaker.id] = attendee
                                }
                            }
                            Divider()
                            Button("Leave as \(speaker.name)") {
                                speakerAssignments.removeValue(forKey: speaker.id)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(speakerAssignments[speaker.id] ?? "Who is this?")
                                    .font(t.typography.bodyMedium)
                                    .foregroundStyle(speakerAssignments[speaker.id] != nil
                                        ? t.colors.accentPrimary
                                        : t.colors.textTertiary)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(t.colors.textTertiary)
                            }
                        }
                    }
                    .padding(.vertical, t.spacing.m)

                    if index < speakers.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(t.spacing.l)
        .surfaceCard()
        .environment(themeManager)
    }

    private func applySpeakerAssignments() {
        guard !speakerAssignments.isEmpty else { return }
        var updated = recording
        for (speakerId, name) in speakerAssignments {
            guard let idx = updated.transcript?.speakers.firstIndex(where: { $0.id == speakerId }) else { continue }
            updated.transcript?.speakers[idx].name = name
            updated.transcript?.speakers[idx].isNameInferred = false
        }
        recording = updated
        store.update(updated)
        speakerAssignments = [:]
        HapticStyle.success.trigger()
    }

    // MARK: - Executive Summary

    private func executiveSummaryCard(_ summary: MeetingSummary, t: AppTheme) -> some View {
        VStack(alignment: .leading, spacing: t.spacing.m) {
            sectionHeader("Summary", icon: "text.quote", t: t)
            Text(summary.executiveSummary)
                .font(t.typography.bodyMedium)
                .foregroundStyle(t.colors.textPrimary)
                .lineSpacing(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(t.spacing.l)
        .surfaceCard()
        .environment(themeManager)
    }

    // MARK: - Decisions

    private func decisionsSection(_ decisions: [Decision], t: AppTheme) -> some View {
        VStack(alignment: .leading, spacing: t.spacing.m) {
            sectionHeader("Decisions", icon: "checkmark.seal.fill", t: t)
            ForEach(decisions) { decision in
                HStack(alignment: .top, spacing: t.spacing.m) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(t.colors.accentSuccess)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(decision.text)
                            .font(t.typography.bodyMedium)
                            .foregroundStyle(t.colors.textPrimary)
                        if let ctx = decision.context {
                            Text(ctx)
                                .font(t.typography.caption)
                                .foregroundStyle(t.colors.textSecondary)
                        }
                        if decision.confidence < 0.85 {
                            ConfidenceBadge(label: "Low-confidence segment", isWarning: true)
                                .environment(themeManager)
                        }
                    }
                }
                if decision.id != decisions.last?.id {
                    Divider().overlay(t.colors.divider)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(t.spacing.l)
        .surfaceCard()
        .environment(themeManager)
    }

    // MARK: - Action Items

    private func actionItemsSection(_ items: [ActionItem], t: AppTheme) -> some View {
        VStack(alignment: .leading, spacing: t.spacing.m) {
            sectionHeader("Action Items", icon: "checkmark.square.fill", t: t)
            ForEach(items) { item in
                ActionItemRow(item: item) { toggleActionItem(item.id) }
                    .environment(themeManager)
                if item.id != items.last?.id {
                    Divider().overlay(t.colors.divider)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(t.spacing.l)
        .surfaceCard()
        .environment(themeManager)
    }

    private func toggleActionItem(_ id: UUID) {
        guard let idx = recording.summary?.actionItems.firstIndex(where: { $0.id == id }) else { return }
        recording.summary?.actionItems[idx].isCompleted.toggle()
        store.update(recording)
    }

    // MARK: - Open Questions

    private func openQuestionsSection(_ questions: [OpenQuestion], t: AppTheme) -> some View {
        VStack(alignment: .leading, spacing: t.spacing.m) {
            sectionHeader("Open Questions", icon: "questionmark.circle.fill", t: t)
            ForEach(questions) { q in
                HStack(alignment: .top, spacing: t.spacing.m) {
                    priorityDot(q.priority, t: t)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(q.text)
                            .font(t.typography.bodyMedium)
                            .foregroundStyle(t.colors.textPrimary)
                        if let owner = q.owner {
                            Text(owner)
                                .font(t.typography.caption)
                                .foregroundStyle(t.colors.textSecondary)
                        }
                    }
                }
                if q.id != questions.last?.id {
                    Divider().overlay(t.colors.divider)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(t.spacing.l)
        .surfaceCard()
        .environment(themeManager)
    }

    private func priorityDot(_ priority: OpenQuestion.Priority, t: AppTheme) -> some View {
        Circle()
            .fill(priorityColor(priority, t: t))
            .frame(width: 8, height: 8)
            .padding(.top, 6)
    }

    private func priorityColor(_ priority: OpenQuestion.Priority, t: AppTheme) -> Color {
        switch priority {
        case .critical: return t.colors.accentError
        case .high: return t.colors.accentWarning
        case .medium: return t.colors.accentSecondary
        case .low: return t.colors.textTertiary
        }
    }

    // MARK: - Risks

    private func risksSection(_ risks: [Risk], t: AppTheme) -> some View {
        VStack(alignment: .leading, spacing: t.spacing.m) {
            sectionHeader("Concerns", icon: "exclamationmark.triangle.fill", t: t)
            ForEach(risks) { risk in
                HStack(alignment: .top, spacing: t.spacing.m) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(severityColor(risk.severity, t: t))
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(risk.title)
                                .font(t.typography.headlineSmall)
                                .foregroundStyle(t.colors.textPrimary)
                            Spacer()
                            Text(risk.severity.displayName)
                                .font(t.typography.labelSmall)
                                .foregroundStyle(severityColor(risk.severity, t: t))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(severityColor(risk.severity, t: t).opacity(0.15))
                                .clipShape(Capsule())
                        }
                        Text(risk.description)
                            .font(t.typography.bodySmall)
                            .foregroundStyle(t.colors.textSecondary)
                    }
                }
                if risk.id != risks.last?.id {
                    Divider().overlay(t.colors.divider)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(t.spacing.l)
        .surfaceCard()
        .environment(themeManager)
    }

    private func severityColor(_ severity: Risk.Severity, t: AppTheme) -> Color {
        switch severity {
        case .critical: return t.colors.accentError
        case .high: return t.colors.accentWarning
        case .medium: return t.colors.accentSecondary
        case .low: return t.colors.textSecondary
        }
    }

    // MARK: - Follow-up Draft

    private func followUpSection(_ draft: String, t: AppTheme) -> some View {
        VStack(alignment: .leading, spacing: t.spacing.m) {
            sectionHeader("Follow-up Draft", icon: "envelope.fill", t: t)
            Text(LocalizedStringKey(draft))
                .font(t.typography.bodySmall)
                .foregroundStyle(t.colors.textSecondary)
                .lineSpacing(3)
                .padding(t.spacing.m)
                .background(t.colors.surfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: t.radius.m))

            Button {
                UIPasteboard.general.string = draft
                HapticStyle.success.trigger()
            } label: {
                Label("Copy draft", systemImage: "doc.on.doc")
                    .font(t.typography.labelLarge)
                    .foregroundStyle(t.colors.accentPrimary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(t.spacing.l)
        .surfaceCard()
        .environment(themeManager)
    }

    // MARK: - Transcript Button

    private func transcriptButton(_ t: AppTheme) -> some View {
        Button {
            showingTranscript = true
        } label: {
            HStack {
                Label("View full transcript", systemImage: "text.alignleft")
                    .font(t.typography.headlineSmall)
                    .foregroundStyle(t.colors.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(t.colors.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(t.spacing.l)
            .surfaceCard()
            .environment(themeManager)
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - Confidence Notes

    private func confidenceNotesSection(_ notes: [String], t: AppTheme) -> some View {
        VStack(alignment: .leading, spacing: t.spacing.s) {
            sectionHeader("Confidence Notes", icon: "exclamationmark.circle", t: t)
            ForEach(notes, id: \.self) { note in
                confidenceNoteRow(note, t: t)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(t.spacing.l)
        .surfaceCard(elevated: false)
        .environment(themeManager)
    }

    @ViewBuilder
    private func confidenceNoteRow(_ note: String, t: AppTheme) -> some View {
        if note.hasPrefix("action:addCredits:") {
            let message = String(note.dropFirst("action:addCredits:".count))
            Link(destination: AnthropicError.billingURL) {
                HStack(alignment: .top, spacing: t.spacing.s) {
                    Image(systemName: "creditcard.trianglebadge.exclamationmark")
                        .font(.system(size: 12))
                        .foregroundStyle(t.colors.accentWarning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(message)
                            .font(t.typography.caption)
                            .foregroundStyle(t.colors.textSecondary)
                            .multilineTextAlignment(.leading)
                        Text("Add credits →")
                            .font(t.typography.caption)
                            .foregroundStyle(t.colors.accentPrimary)
                    }
                }
            }
        } else {
            HStack(alignment: .top, spacing: t.spacing.s) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(t.colors.accentWarning)
                Text(note)
                    .font(t.typography.caption)
                    .foregroundStyle(t.colors.textSecondary)
            }
        }
    }

    // MARK: - No Summary State

    private func noSummaryState(_ t: AppTheme) -> some View {
        VStack(spacing: t.spacing.l) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 36))
                .foregroundStyle(t.colors.textTertiary)
            Text("Processing in progress")
                .font(t.typography.headlineMedium)
                .foregroundStyle(t.colors.textSecondary)
            Text("Notes will appear here once processing is complete.")
                .font(t.typography.bodySmall)
                .foregroundStyle(t.colors.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(t.spacing.huge)
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String, icon: String, t: AppTheme) -> some View {
        HStack(spacing: t.spacing.s) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(t.colors.accentPrimary)
            Text(title)
                .font(t.typography.labelLarge)
                .foregroundStyle(t.colors.textSecondary)
                .textCase(.uppercase)
                .tracking(0.6)
        }
    }

    // MARK: - Actions

    private func copyToClipboard() {
        guard let summary = recording.summary else { return }
        UIPasteboard.general.string = buildMarkdown(summary)
        HapticStyle.success.trigger()
    }

    private func exportMarkdown() {
        guard let summary = recording.summary else { return }
        exportedText = buildMarkdown(summary)
        showShareSheet = true
    }

    private func buildMarkdown(_ summary: MeetingSummary) -> String {
        var md = "# \(recording.title)\n"
        md += "_\(recording.startedAt.relativeLabel()) · \(recording.duration.shortString) · \(recording.mode.displayName)_\n\n"
        md += "## Summary\n\(summary.executiveSummary)\n\n"
        if !summary.markedMoments.isEmpty {
            md += "## Marked Moments\n"
            summary.markedMoments.forEach { moment in
                md += "- [\(formatTimestamp(moment.timestamp))] \(moment.summary)\n"
            }
            md += "\n"
        }
        if !summary.decisions.isEmpty {
            md += "## Decisions\n"
            summary.decisions.forEach { md += "- \($0.text)\n" }
            md += "\n"
        }
        if !summary.actionItems.isEmpty {
            md += "## Action Items\n"
            summary.actionItems.forEach {
                let owner = $0.owner.map { " (@\($0))" } ?? ""
                md += "- [ ] \($0.title)\($0.isOwnerInferred ? " [inferred]" : "")\(owner)\n"
            }
            md += "\n"
        }
        if !summary.openQuestions.isEmpty {
            md += "## Open Questions\n"
            summary.openQuestions.forEach { md += "- \($0.text)\n" }
            md += "\n"
        }
        if !summary.followUpDraft.isEmpty {
            md += "## Follow-up Draft\n\(summary.followUpDraft)\n"
        }
        return md
    }

    private func formatTimestamp(_ time: TimeInterval) -> String {
        let t = max(0, time)
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Action Item Row

struct ActionItemRow: View {
    @Environment(ThemeManager.self) private var themeManager
    let item: ActionItem
    var onToggle: () -> Void = {}

    var body: some View {
        let t = themeManager.currentTheme
        HStack(alignment: .top, spacing: t.spacing.m) {
            Button {
                onToggle()
                HapticStyle.light.trigger()
            } label: {
                Image(systemName: item.isCompleted ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18))
                    .foregroundStyle(item.isCompleted ? t.colors.accentSuccess : t.colors.textTertiary)
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(t.typography.bodyMedium)
                    .foregroundStyle(t.colors.textPrimary)
                    .strikethrough(item.isCompleted)

                HStack(spacing: t.spacing.s) {
                    if let owner = item.owner {
                        HStack(spacing: 3) {
                            Image(systemName: "person")
                                .font(.system(size: 10))
                            Text(owner)
                                .font(t.typography.caption)
                        }
                        .foregroundStyle(t.colors.textSecondary)

                        if item.isOwnerInferred {
                            ConfidenceBadge(label: "Owner inferred", isWarning: false)
                                .environment(themeManager)
                        }
                    }
                    if let due = item.dueDate {
                        HStack(spacing: 3) {
                            Image(systemName: "calendar")
                                .font(.system(size: 10))
                            Text(due.relativeLabel())
                                .font(t.typography.caption)
                        }
                        .foregroundStyle(t.colors.textSecondary)
                        if item.isDueDateInferred {
                            ConfidenceBadge(label: "Date inferred", isWarning: false)
                                .environment(themeManager)
                        }
                    }
                }
                priorityBadge(item.priority, t: t)
            }
        }
    }

    private func priorityBadge(_ priority: ActionItem.Priority, t: AppTheme) -> some View {
        let color: Color = {
            switch priority {
            case .high: return t.colors.accentError
            case .medium: return t.colors.accentWarning
            case .low: return t.colors.textTertiary
            }
        }()
        return Text(priority.displayName)
            .font(t.typography.labelSmall)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}

// MARK: - Audio Player

struct AudioPlayerView: View {
    @Environment(ThemeManager.self) private var themeManager
    let seed: Int
    let duration: TimeInterval
    let audioFileID: String
    @Binding var seekTime: TimeInterval?

    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var isDragging = false
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        let t = themeManager.currentTheme
        let progress = duration > 0 ? currentTime / duration : 0
        VStack(spacing: t.spacing.s) {
            PlaybackWaveformView(
                seed: seed,
                progress: progress,
                playedColor: t.colors.accentPrimary,
                unplayedColor: t.colors.accentPrimary
            )

            Slider(value: $currentTime, in: 0...max(duration, 1)) { editing in
                isDragging = editing
                if editing {
                    player?.pause()
                } else {
                    player?.currentTime = currentTime
                    if isPlaying { player?.play() }
                }
            }
            .tint(t.colors.accentPrimary)

            HStack {
                Text(formatTime(currentTime))
                    .font(t.typography.caption)
                    .foregroundStyle(t.colors.textSecondary)
                    .monospacedDigit()
                    .frame(width: 40, alignment: .leading)

                Spacer()

                Button { togglePlayback() } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(player != nil ? t.colors.accentPrimary : t.colors.textTertiary)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(player == nil)

                Spacer()

                Text(formatTime(duration))
                    .font(t.typography.caption)
                    .foregroundStyle(t.colors.textTertiary)
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
        }
        .task { preparePlayer() }
        .onChange(of: seekTime) { _, newValue in
            guard let newValue else { return }
            seekAndPlay(to: newValue)
            seekTime = nil
        }
        .onDisappear {
            player?.stop()
            pollTask?.cancel()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func seekAndPlay(to time: TimeInterval) {
        guard let player else { return }
        let target = min(max(0, time), player.duration)
        currentTime = target
        player.currentTime = target
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        isPlaying = true
        startPolling()
    }

    private func preparePlayer() {
        let fileURL = AVAudioRecorderService.recordingsDirectory.appendingPathComponent(audioFileID)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let p = try? AVAudioPlayer(contentsOf: fileURL) else { return }
        p.prepareToPlay()
        player = p
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            pollTask?.cancel()
        } else {
            if player.currentTime >= player.duration { player.currentTime = 0; currentTime = 0 }
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
            isPlaying = true
            startPolling()
        }
        HapticStyle.light.trigger()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            do {
                while true {
                    try await Task.sleep(for: .milliseconds(100))
                    guard let player else { break }
                    if !isDragging { currentTime = player.currentTime }
                    if !player.isPlaying {
                        isPlaying = false
                        currentTime = 0
                        break
                    }
                }
            } catch {}
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let t = max(0, time)
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let text: String
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

#Preview {
    MeetingSummaryDetailView(recording: MockMeetings.mobileKickoffRecording)
        .environment(ThemeManager())
        .environment(RecordingsStore())
        .preferredColorScheme(.dark)
}
