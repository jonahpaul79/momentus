import AVFoundation
import SwiftUI

private struct TranscriptChatLaunch: Identifiable {
    let id = UUID()
    let question: String?
}

struct MeetingSummaryDetailView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(RecordingsStore.self) private var store
    @State var recording: Recording
    @State private var showingTranscript = false
    @State private var transcriptChatLaunch: TranscriptChatLaunch?
    @State private var showShareSheet = false
    @State private var exportedText = ""
    @State private var playbackSeekTime: TimeInterval?
    @State private var speakerAssignments: [UUID: String] = [:]
    @State private var customNameSpeakerID: UUID?
    @State private var customSpeakerName = ""
    @State private var showingCustomSpeakerName = false
    @State private var showingBestQualityConfirmation = false
    @State private var showingRegenerateConfirmation = false
    @State private var showingRenameRecording = false
    @State private var recordingTitleDraft = ""
    @Environment(\.dismiss) private var dismiss
    @AppStorage("audioRetention") private var audioRetentionRaw: String = AudioRetentionPolicy.deleteAfterTranscript.rawValue

    private var hasAudio: Bool {
        guard let audioFileID = recording.audioFileID,
              !audioFileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        let policy = AudioRetentionPolicy(rawValue: audioRetentionRaw) ?? .deleteAfterTranscript
        return policy != .deleteAfterTranscript
    }

    private var isRecordingProcessing: Bool {
        recording.processingState.isInProgress
            || store.processingRecordingIDs.contains(recording.id)
    }

    var body: some View {
        let t = themeManager.currentTheme
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView(.vertical) {
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

                if recording.transcript != nil {
                    pinnedTranscriptChatBar(t)
                }
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
                        Button { beginRenamingRecording() } label: {
                            Label("Rename recording", systemImage: "pencil")
                        }
                        .disabled(isRecordingProcessing)
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
                        if recording.transcript != nil || store.canRetryProcessing(recording) {
                            Button {
                                if recording.summary != nil {
                                    showingRegenerateConfirmation = true
                                } else {
                                    store.retryProcessing(recordingID: recording.id)
                                    HapticStyle.medium.trigger()
                                }
                            } label: {
                                Label("Regenerate notes", systemImage: "arrow.clockwise")
                            }
                            .disabled(store.processingRecordingIDs.contains(recording.id))
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
            .sheet(item: $transcriptChatLaunch) { launch in
                TranscriptChatView(
                    recording: recording,
                    initialQuestion: launch.question
                )
                    .environment(themeManager)
            }
            .sheet(isPresented: $showShareSheet) {
                ShareSheet(text: exportedText)
            }
            .alert("Name this speaker", isPresented: $showingCustomSpeakerName) {
                TextField("Name", text: $customSpeakerName)
                    .textInputAutocapitalization(.words)
                Button("Cancel", role: .cancel) {
                    customNameSpeakerID = nil
                    customSpeakerName = ""
                }
                Button("Assign") {
                    assignCustomSpeakerName()
                }
                .disabled(customSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                Text("This name will be used in the transcript and notes.")
            }
            .alert("Rename Recording", isPresented: $showingRenameRecording) {
                TextField("Recording name", text: $recordingTitleDraft)
                    .textInputAutocapitalization(.sentences)
                Button("Cancel", role: .cancel) {}
                Button("Save") { saveRecordingTitle() }
                    .disabled(recordingTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                Text("Your title will be kept when notes are regenerated.")
            }
            .alert("Regenerate Notes?", isPresented: $showingRegenerateConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Regenerate") {
                    store.regenerateNotes(recordingID: recording.id)
                    HapticStyle.medium.trigger()
                }
            } message: {
                Text("The current notes will be replaced with a new AI-generated summary from the existing transcript.")
            }
            .alert("Reprocess with Best Quality?", isPresented: $showingBestQualityConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Reprocess") {
                    store.reprocessWithBestQuality(recordingID: recording.id)
                    HapticStyle.medium.trigger()
                }
            } message: {
                Text("The original audio will be sent to AssemblyAI for a new transcript with speaker separation, then the notes will be regenerated.")
            }
        }
        .presentationContentInteraction(.resizes)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            if let updated = store.recording(for: recording.id) { recording = updated }
        }
        .onChange(of: store.recording(for: recording.id)) { _, updated in
            if let updated { recording = updated }
        }
        .onReceive(NotificationCenter.default.publisher(for: .recordingProcessingCompleted)) { notification in
            guard let id = notification.userInfo?["recordingId"] as? UUID,
                  id == recording.id,
                  let updated = store.recording(for: recording.id)
            else { return }
            recording = updated
        }
    }

    // MARK: - Header

    private func meetingHeader(_ t: AppTheme) -> some View {
        VStack(alignment: .leading, spacing: t.spacing.m) {
            HStack(alignment: .firstTextBaseline, spacing: t.spacing.s) {
                Text(recording.title)
                    .font(t.typography.displayMedium)
                    .foregroundStyle(t.colors.textPrimary)

                Button { beginRenamingRecording() } label: {
                    Image(systemName: "pencil.circle")
                        .font(.title3)
                        .foregroundStyle(t.colors.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(isRecordingProcessing)
                .accessibilityLabel("Rename recording")
            }

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
                    recordingID: recording.id,
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

    private func beginRenamingRecording() {
        recordingTitleDraft = recording.title
        showingRenameRecording = true
    }

    private func saveRecordingTitle() {
        store.rename(recordingID: recording.id, title: recordingTitleDraft)
        if let updated = store.recording(for: recording.id) {
            recording = updated
        }
        HapticStyle.medium.trigger()
    }

    // MARK: - Summary Content

    private func summaryContent(_ summary: MeetingSummary, t: AppTheme) -> some View {
        let processingIssues = processingIssueNotes(from: summary.confidenceNotes)

        return VStack(alignment: .leading, spacing: t.spacing.l) {
            if let speakers = recording.transcript?.speakers, !speakers.isEmpty {
                speakerIdentificationCard(
                    speakers: speakers,
                    attendees: recording.calendarAttendees ?? [],
                    t: t
                )
            }
            if recording.mode != .bestQuality {
                bestQualityReprocessCard(t)
            }
            executiveSummaryCard(summary, t: t)
            if !summary.markedMoments.isEmpty { markedMomentsSection(summary.markedMoments, t: t) }
            if !summary.decisions.isEmpty { decisionsSection(summary.decisions, t: t) }
            if !summary.actionItems.isEmpty { actionItemsSection(summary.actionItems, t: t) }
            if !summary.openQuestions.isEmpty { openQuestionsSection(summary.openQuestions, t: t) }
            if !summary.risks.isEmpty { risksSection(summary.risks, t: t) }
            if !summary.followUpDraft.isEmpty { followUpSection(summary.followUpDraft, t: t) }
            if recording.transcript != nil {
                transcriptButton(t)
            }
            if !processingIssues.isEmpty {
                processingIssuesSection(processingIssues, t: t)
            }
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
        let detectedNames: [String] = {
            guard let csv = recording.transcript?.providerData["detected_person_names"], !csv.isEmpty else { return [] }
            return csv.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }()

        return VStack(alignment: .leading, spacing: t.spacing.m) {
            HStack(spacing: t.spacing.s) {
                Image(systemName: "person.2.wave.2")
                    .font(.system(size: 13))
                    .foregroundStyle(t.colors.accentPrimary)
                Text("SPEAKERS")
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

            Text(attendees.isEmpty && detectedNames.isEmpty
                ? "Assign a name to each voice in the transcript and notes."
                : "Choose from the suggestions below or enter another name.")
                .font(t.typography.bodySmall)
                .foregroundStyle(t.colors.textSecondary)

            if recording.transcript?.provider != "AssemblyAI" {
                Label(
                    "Private mode does not separate multiple voices. Best Quality can create distinct speaker labels.",
                    systemImage: "lock.shield"
                )
                .font(t.typography.caption)
                .foregroundStyle(t.colors.textTertiary)
            }

            VStack(spacing: 0) {
                ForEach(Array(speakers.enumerated()), id: \.element.id) { index, speaker in
                    HStack {
                        Text(speaker.name)
                            .font(t.typography.bodyMedium)
                            .foregroundStyle(t.colors.textPrimary)
                        Spacer()
                        Menu {
                            if !attendees.isEmpty {
                                Section("Calendar invite") {
                                    ForEach(attendees, id: \.self) { attendee in
                                        Button(attendee) {
                                            speakerAssignments[speaker.id] = attendee
                                        }
                                    }
                                }
                            }
                            if !detectedNames.isEmpty {
                                Section("Names from conversation") {
                                    ForEach(detectedNames, id: \.self) { name in
                                        Button(name) {
                                            speakerAssignments[speaker.id] = name
                                        }
                                    }
                                }
                            }
                            Button("Enter a name…", systemImage: "pencil") {
                                beginCustomSpeakerName(for: speaker)
                            }
                            if speakerAssignments[speaker.id] != nil {
                                Button("Discard change", role: .destructive) {
                                    speakerAssignments.removeValue(forKey: speaker.id)
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(speakerAssignments[speaker.id]
                                    ?? (speaker.requiresIdentification ? "Assign name" : "Change"))
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
        var replacements: [String: String] = [:]
        for (speakerId, name) in speakerAssignments {
            guard let idx = updated.transcript?.speakers.firstIndex(where: { $0.id == speakerId }) else { continue }
            let oldName = updated.transcript?.speakers[idx].name ?? ""
            replacements[oldName] = name
            updated.transcript?.providerData["momentus_original_speaker_\(speakerId.uuidString)"] = oldName
            updated.transcript?.speakers[idx].name = name
            updated.transcript?.speakers[idx].isNameInferred = false
        }
        updated.summary?.renameSpeakerReferences(replacements)
        recording = updated
        store.update(updated)
        speakerAssignments = [:]
        HapticStyle.success.trigger()
    }

    private func beginCustomSpeakerName(for speaker: Speaker) {
        customNameSpeakerID = speaker.id
        customSpeakerName = speaker.requiresIdentification
            ? ""
            : (speakerAssignments[speaker.id] ?? speaker.name)
        showingCustomSpeakerName = true
    }

    private func assignCustomSpeakerName() {
        let name = customSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let speakerID = customNameSpeakerID, !name.isEmpty else { return }
        speakerAssignments[speakerID] = name
        customNameSpeakerID = nil
        customSpeakerName = ""
    }

    @ViewBuilder
    private func bestQualityReprocessCard(_ t: AppTheme) -> some View {
        let availability = store.bestQualityReprocessAvailability(for: recording)
        VStack(alignment: .leading, spacing: t.spacing.m) {
            sectionHeader("Improve Quality", icon: "sparkles", t: t)

            switch availability {
            case .available:
                Text("Re-transcribe the saved audio with cloud speaker separation and regenerate all notes.")
                    .font(t.typography.bodySmall)
                    .foregroundStyle(t.colors.textSecondary)
                Button {
                    showingBestQualityConfirmation = true
                } label: {
                    Label("Reprocess with Best Quality", systemImage: "arrow.triangle.2.circlepath")
                        .font(t.typography.headlineSmall)
                        .foregroundStyle(t.colors.textOnAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, t.spacing.m)
                        .background(t.colors.accentPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: t.radius.m))
                }
                .buttonStyle(PlainButtonStyle())

            case .processing:
                HStack(spacing: t.spacing.m) {
                    ProgressView().tint(t.colors.accentPrimary)
                    Text(recording.processingState.displayName)
                        .font(t.typography.bodyMedium)
                        .foregroundStyle(t.colors.textSecondary)
                }

            case .audioUnavailable:
                Text("The original audio is no longer available, so this recording cannot be re-transcribed.")
                    .font(t.typography.bodySmall)
                    .foregroundStyle(t.colors.textTertiary)

            case .missingAPIKey:
                Text("Momentus Cloud is required to use Best Quality transcription.")
                    .font(t.typography.bodySmall)
                    .foregroundStyle(t.colors.textTertiary)

            case .alreadyBestQuality:
                EmptyView()
            }

            if let error = recording.processingError,
               error.hasPrefix("Best Quality reprocessing failed:") {
                Text(error)
                    .font(t.typography.caption)
                    .foregroundStyle(t.colors.accentError)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(t.spacing.l)
        .surfaceCard()
        .environment(themeManager)
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
                        if decision.confidence < 0.65 {
                            HStack(spacing: 4) {
                                Image(systemName: "text.magnifyingglass")
                                    .font(.system(size: 10))
                                Text("Review source")
                                    .font(t.typography.labelSmall)
                            }
                            .foregroundStyle(t.colors.textTertiary)
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
                Button {
                    presentTranscriptChat(question: q.text)
                } label: {
                    HStack(alignment: .top, spacing: t.spacing.m) {
                        priorityDot(q.priority, t: t)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(q.text)
                                .font(t.typography.bodyMedium)
                                .foregroundStyle(t.colors.textPrimary)
                                .multilineTextAlignment(.leading)
                            HStack(spacing: t.spacing.s) {
                                if let owner = q.owner {
                                    Text(owner)
                                    Text("·")
                                }
                                Label("Ask Momentus", systemImage: "sparkles")
                                    .foregroundStyle(t.colors.accentPrimary)
                            }
                            .font(t.typography.caption)
                            .foregroundStyle(t.colors.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(t.colors.textTertiary)
                            .padding(.top, 3)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(recording.transcript == nil)
                .accessibilityHint("Opens Ask Momentus and asks this question")
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

    // MARK: - Transcript Actions

    private func pinnedTranscriptChatBar(_ t: AppTheme) -> some View {
        Button {
            presentTranscriptChat()
        } label: {
            HStack(spacing: t.spacing.m) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(t.colors.accentPrimary)
                    .frame(width: 30, height: 30)
                    .background(t.colors.accentPrimary.opacity(0.14))
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ask Momentus")
                        .font(t.typography.headlineSmall)
                        .foregroundStyle(t.colors.textPrimary)
                    Text("Ask about this meeting…")
                        .font(t.typography.caption)
                        .foregroundStyle(t.colors.textSecondary)
                }
                Spacer()
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(t.colors.textOnAccent)
                    .frame(width: 36, height: 36)
                    .background(t.colors.accentPrimary)
                    .clipShape(Circle())
            }
            .padding(.horizontal, t.spacing.l)
            .padding(.vertical, t.spacing.m)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(t.colors.divider)
                    .frame(height: 0.5)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityHint("Opens chat for this meeting and focuses the message field")
    }

    private func presentTranscriptChat(question: String? = nil) {
        transcriptChatLaunch = TranscriptChatLaunch(question: question)
        HapticStyle.light.trigger()
    }

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

    // MARK: - Processing Issues

    private func processingIssueNotes(from notes: [String]) -> [String] {
        notes.filter { $0.hasPrefix("action:") }
    }

    private func processingIssuesSection(_ notes: [String], t: AppTheme) -> some View {
        VStack(alignment: .leading, spacing: t.spacing.s) {
            sectionHeader("Processing Issue", icon: "creditcard.trianglebadge.exclamationmark", t: t)
            ForEach(notes, id: \.self) { note in
                processingIssueRow(note, t: t)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(t.spacing.l)
        .surfaceCard(elevated: false)
        .environment(themeManager)
    }

    @ViewBuilder
    private func processingIssueRow(_ note: String, t: AppTheme) -> some View {
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

    @ViewBuilder
    private func noSummaryState(_ t: AppTheme) -> some View {
        if recording.processingState == .failed {
            failedProcessingState(t)
        } else {
            inProgressState(t)
        }
    }

    private func inProgressState(_ t: AppTheme) -> some View {
        VStack(spacing: t.spacing.l) {
            ProgressView()
                .controlSize(.large)
                .tint(t.colors.accentPrimary)
            Text("Processing in progress")
                .font(t.typography.headlineMedium)
                .foregroundStyle(t.colors.textSecondary)
            Text(recording.processingDetail ?? "\(recording.processingState.displayName). You can leave this screen while the app continues working.")
                .font(t.typography.bodySmall)
                .foregroundStyle(t.colors.textTertiary)
                .multilineTextAlignment(.center)
            if let progress = recording.processingProgress {
                ProgressView(value: progress)
                    .tint(t.colors.accentPrimary)
                    .frame(maxWidth: 260)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(t.spacing.huge)
    }

    private func failedProcessingState(_ t: AppTheme) -> some View {
        VStack(spacing: t.spacing.l) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 42))
                .foregroundStyle(t.colors.accentError)

            VStack(spacing: t.spacing.s) {
                Text("AI processing failed")
                    .font(t.typography.headlineMedium)
                    .foregroundStyle(t.colors.textPrimary)
                Text(recording.processingError ?? "Your recording was preserved, but notes could not be generated.")
                    .font(t.typography.bodySmall)
                    .foregroundStyle(t.colors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            if store.canRetryProcessing(recording) {
                Button {
                    store.retryProcessing(recordingID: recording.id)
                    HapticStyle.medium.trigger()
                } label: {
                    Label("Retry AI processing", systemImage: "arrow.clockwise")
                        .font(t.typography.headlineMedium)
                        .foregroundStyle(t.colors.textOnAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, t.spacing.m)
                        .background(t.colors.accentPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: t.radius.l))
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                Text("The saved audio is not available, so this recording cannot be retried.")
                    .font(t.typography.caption)
                    .foregroundStyle(t.colors.textTertiary)
                    .multilineTextAlignment(.center)
            }

            if recording.transcript != nil {
                Button("View saved transcript") { showingTranscript = true }
                    .font(t.typography.bodyMedium)
                    .foregroundStyle(t.colors.accentPrimary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(t.spacing.l)
        .surfaceCard()
        .environment(themeManager)
        .padding(.horizontal, t.spacing.l)
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
    let recordingID: UUID
    let seed: Int
    let duration: TimeInterval
    let audioFileID: String
    @Binding var seekTime: TimeInterval?

    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var isDragging = false
    @State private var pollTask: Task<Void, Never>?
    @State private var waveformLevels: [CGFloat]?

    var body: some View {
        let t = themeManager.currentTheme
        let progress = duration > 0 ? currentTime / duration : 0
        VStack(spacing: t.spacing.s) {
            PlaybackWaveformView(
                seed: seed,
                levels: waveformLevels,
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
                    .lineLimit(1)
                    .frame(minWidth: 40, alignment: .leading)

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
                    .lineLimit(1)
                    .frame(minWidth: 40, alignment: .trailing)
            }
        }
        .task(id: audioFileID) { await prepareAudio() }
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

    private func prepareAudio() async {
        let fileURL = AVAudioRecorderService.recordingsDirectory.appendingPathComponent(audioFileID)
        if await loadPlayer(from: fileURL) {
            await loadWaveform(from: fileURL)
            return
        }

        guard let restoredURL = await CloudKitService.shared.restoreAudioAsset(
            recordingID: recordingID,
            audioFileID: audioFileID
        ) else {
            print("[AudioPlayer] missing audio file: \(audioFileID)")
            waveformLevels = nil
            return
        }

        guard await loadPlayer(from: restoredURL) else {
            waveformLevels = nil
            return
        }
        await loadWaveform(from: restoredURL)
    }

    private func loadPlayer(from fileURL: URL) async -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return false
        }

        let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard fileSize >= 1024 else {
            print("[AudioPlayer] audio file too small: \(fileURL.lastPathComponent) (\(fileSize) bytes)")
            return false
        }

        let p: AVAudioPlayer
        do {
            p = try AVAudioPlayer(contentsOf: fileURL)
        } catch {
            do {
                let data = try Data(contentsOf: fileURL)
                p = try AVAudioPlayer(data: data)
            } catch {
                print("[AudioPlayer] could not open \(fileURL.lastPathComponent) (\(fileSize) bytes): \(error.localizedDescription)")
                return false
            }
        }
        p.prepareToPlay()
        player = p
        return true
    }

    private func loadWaveform(from fileURL: URL) async {
        let levels = await Task.detached(priority: .utility) {
            try? AudioWaveformAnalyzer.levels(for: fileURL)
        }.value
        if let levels, !levels.isEmpty {
            waveformLevels = levels
        }
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
