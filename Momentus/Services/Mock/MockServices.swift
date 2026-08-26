import AVFoundation
import Foundation
import UIKit

// MARK: - Recordings Store

/// The single source of truth for all `Recording` objects in the app.
///
/// Created once in `ContentView` and injected via `.environment(store)`.
/// Both `RecordViewModel` (writes during processing) and `NotesListView`
/// (reads for display) reference the same instance.
///
/// Mutation always happens on the main actor (implicit via `SWIFT_DEFAULT_ACTOR_ISOLATION`).
/// `@Observable` means any view reading `store.recordings` re-renders automatically.
@Observable final class RecordingsStore {
    private let storageKey = "stored_recordings"
    static let interruptedProcessingMessage = "Processing was interrupted before it finished. Your recording is preserved and will resume automatically."
    static func failureMessage(stage: ProcessingState, error: Error) -> String {
        if stage == .failed { return error.localizedDescription }
        return "\(stage.displayName) failed: \(error.localizedDescription)"
    }
    var recordings: [Recording] = []
    var isSyncing = false
    private(set) var processingRecordingIDs: Set<UUID> = []
    private let transcriptChatStore = TranscriptChatStore()
    private var audioRetentionTask: Task<Void, Never>?
    private let remoteTranscriptDeletionKey = "pending_assemblyai_transcript_deletions"
    private var isProcessingRemoteTranscriptDeletions = false
    /// A regeneration uses the mode currently selected in Settings, but does not
    /// rewrite the privacy mode originally stored with the recording.
    private var summaryModeOverrides: [UUID: RecordingMode] = [:]

    private var isCloudEnabled: Bool {
        UserDefaults.standard.bool(forKey: "iCloudSync")
    }

    init(loadSamples: Bool = true) {
        Self.migrateAudioRetentionDefaultIfNeeded()
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([Recording].self, from: data),
           !saved.isEmpty {
            recordings = saved.map { stored in
                var recovered = stored
                if recovered.processingState.isInProgress {
                    recovered.processingState = .failed
                    recovered.processingError = Self.interruptedProcessingMessage
                } else if recovered.processingState == .failed,
                          recovered.processingError?.isEmpty != false {
                    recovered.processingError = "AI processing did not finish. Your recording is preserved and can be retried."
                }
                return recovered
            }
            if recordings != saved { persist() }
        } else if loadSamples {
            recordings = MockMeetings.sampleRecordings
        }
        Task {
            await syncFromCloud()
            await applyAudioRetentionPolicy()
            await processPendingRemoteTranscriptDeletions()
        }
    }

    /// Retention choices existed before cleanup was implemented. Treat every
    /// existing install as Keep Forever once so enabling the feature cannot
    /// unexpectedly erase a backlog of recordings.
    private static func migrateAudioRetentionDefaultIfNeeded() {
        let migrationKey = "audioRetentionPolicyVersion"
        guard UserDefaults.standard.integer(forKey: migrationKey) < 1 else { return }
        UserDefaults.standard.set(AudioRetentionPolicy.keepForever.rawValue, forKey: "audioRetention")
        UserDefaults.standard.set(1, forKey: migrationKey)
    }

    func add(_ recording: Recording) {
        recordings.insert(recording, at: 0)
        persist()
        cloudSave(recording)
    }

    func update(_ recording: Recording) {
        guard let idx = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        recordings[idx] = recording
        persist()
        cloudSave(recording)
        scheduleAudioRetentionSweep()
    }

    func delete(id: UUID) {
        guard let recording = recording(for: id) else { return }
        delete(recording)
    }

    func delete(_ recording: Recording) {
        recordings.removeAll { $0.id == recording.id }
        persist()
        transcriptChatStore.delete(recordingID: recording.id)
        scheduleAudioRetentionSweep()
        let transcriptID = recording.transcript?.providerData["assemblyai_transcript_id"]
        if let transcriptID, !transcriptID.isEmpty {
            enqueueRemoteTranscriptDeletion(transcriptID)
        }
        Task {
            if let fileID = recording.audioFileID {
                let url = AVAudioRecorderService.recordingsDirectory.appendingPathComponent(fileID)
                try? FileManager.default.removeItem(at: url)
            }
            await CloudKitService.shared.delete(id: recording.id)
            await processPendingRemoteTranscriptDeletions()
        }
    }

    func toggle(favorite id: UUID) {
        guard let idx = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings[idx].isFavorite.toggle()
        persist()
        cloudSave(recordings[idx])
    }

    func rename(recordingID: UUID, title: String) {
        let cleaned = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !cleaned.isEmpty,
              let index = recordings.firstIndex(where: { $0.id == recordingID })
        else { return }

        recordings[index].title = String(cleaned.prefix(120))
        recordings[index].titleWasEditedByUser = true
        persist()
        cloudSave(recordings[index])
    }

    func recording(for id: UUID) -> Recording? {
        recordings.first { $0.id == id }
    }

    // MARK: - Processing Retry

    func canRetryProcessing(_ recording: Recording) -> Bool {
        guard recording.processingState == .failed else { return false }
        return recording.transcript != nil || audioIsPlayable(recording.audioFileID)
    }

    /// Reuses any completed transcript and only repeats the failed portion of the pipeline.
    /// The task is owned by the app-level store, so dismissing the detail screen does not cancel it.
    func retryProcessing(recordingID: UUID, userInitiated: Bool = true) {
        guard !processingRecordingIDs.contains(recordingID),
              var recording = recording(for: recordingID),
              canRetryProcessing(recording)
        else { return }

        processingRecordingIDs.insert(recordingID)
        recording.processingError = nil
        let retryMode = Self.processingMode(for: recording, userInitiated: userInitiated)
        if retryMode != recording.mode {
            print("[Retry Pipeline] switching from \(recording.mode.rawValue) to current setting \(retryMode.rawValue)")
            recording.mode = retryMode
            recording.transcriptionJobID = nil
            recording.transcriptionJobCreatedAt = nil
        }
        if recording.transcript != nil {
            recording.processingState = .summarizing
            recording.processingDetail = "Generating meeting notes"
        } else if recording.hasUsableTranscriptionCheckpoint {
            recording.processingState = .transcribing
            recording.processingDetail = "Resuming cloud transcription"
        } else if recording.mode == .bestQuality {
            recording.processingState = .uploading
            recording.processingDetail = "Preparing resumable upload"
            recording.processingProgress = 0
        } else {
            recording.processingState = .transcribing
            recording.processingDetail = "Preparing on-device transcription"
        }
        update(recording)

        Task { [weak self] in
            await self?.performProcessingRetry(recordingID: recordingID, userInitiated: userInitiated)
        }
    }

    static func processingMode(for recording: Recording, userInitiated: Bool) -> RecordingMode {
        // A person tapping Retry reasonably expects the mode currently selected in
        // Settings. Automatic crash recovery must preserve the recording's mode.
        guard userInitiated, recording.transcript == nil,
              let raw = UserDefaults.standard.string(forKey: "defaultRecordingMode"),
              let selected = RecordingMode(rawValue: raw)
        else { return recording.mode }
        return selected
    }

    /// Clears any existing summary and re-runs the summarization step from the saved transcript.
    func regenerateNotes(recordingID: UUID) {
        guard !processingRecordingIDs.contains(recordingID),
              var recording = recording(for: recordingID),
              recording.transcript != nil
        else { return }

        if let raw = UserDefaults.standard.string(forKey: "defaultRecordingMode"),
           let selectedMode = RecordingMode(rawValue: raw) {
            summaryModeOverrides[recordingID] = selectedMode
            print("[Regenerate Notes] using current setting: \(selectedMode.rawValue)")
        }

        recording.summary = nil
        recording.processingState = .failed
        recording.processingError = nil
        recording.processingProgress = nil
        recording.processingDetail = nil
        update(recording)
        retryProcessing(recordingID: recordingID, userInitiated: true)
    }

    /// Continue work that was persisted in an in-progress state before the app exited.
    /// Cloud recordings reuse their saved provider job ID rather than uploading again.
    func resumeInterruptedProcessing() {
        // A continued task can be terminated by the system while this process is
        // still alive. Reconcile any iPhone recording that says it is processing
        // but has no app or system operation before attempting the saved retry.
        for index in recordings.indices where
            recordings[index].micSource == .iPhone
                && recordings[index].processingState.isInProgress
                && !processingRecordingIDs.contains(recordings[index].id)
                && !ContinuedProcessingManager.shared.isProcessing(recordingID: recordings[index].id) {
            recordings[index].processingState = .failed
            recordings[index].processingError = Self.interruptedProcessingMessage
        }
        persist()

        let resumableCloudIDs = recordings.compactMap { recording in
            recording.processingState == .failed
                && recording.processingError == Self.interruptedProcessingMessage
                && recording.hasUsableTranscriptionCheckpoint
                ? recording.id
                : nil
        }
        // Only a checkpointed provider job is safe to resume automatically. An
        // interrupted local transcription or upload waits for an explicit Retry,
        // allowing the person's current processing mode to be applied first.
        for id in resumableCloudIDs {
            retryProcessing(recordingID: id, userInitiated: false)
        }
    }

    // MARK: - Best Quality Reprocessing

    func bestQualityReprocessAvailability(for recording: Recording) -> BestQualityReprocessAvailability {
        if recording.mode == .bestQuality { return .alreadyBestQuality }
        if processingRecordingIDs.contains(recording.id) { return .processing }
        guard audioIsPlayable(recording.audioFileID) else { return .audioUnavailable }
        guard ServiceFactory.isTranscriptionConfigured(for: .bestQuality) else { return .missingAPIKey }
        return .available
    }

    /// Re-transcribes the original audio with cloud speaker diarization and
    /// regenerates notes. Existing Private-mode results are restored on failure.
    func reprocessWithBestQuality(recordingID: UUID) {
        guard !processingRecordingIDs.contains(recordingID),
              let original = recording(for: recordingID),
              bestQualityReprocessAvailability(for: original) == .available
        else { return }

        processingRecordingIDs.insert(recordingID)
        var processing = original
        processing.processingState = .transcribing
        processing.processingError = nil
        update(processing)

        Task { [weak self] in
            await self?.performBestQualityReprocess(original: original)
        }
    }

    private func performBestQualityReprocess(original: Recording) async {
        defer { processingRecordingIDs.remove(original.id) }

        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "BestQualityReprocess") {
            print("[Best Quality Reprocess] background execution time expired")
        }
        defer {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }

        do {
            guard let audioFileID = original.audioFileID,
                  audioIsPlayable(audioFileID)
            else { throw RecordingProcessingRetryError.audioUnavailable }

            var transcript = try await ServiceFactory.makeTranscriptionService(for: .bestQuality)
                .transcribe(audioFileID: audioFileID, recordingId: original.id)
            transcript.providerData["momentus_markers"] = original.markers
                .map { String(format: "%.1f", $0) }
                .joined(separator: ",")
            if let attendees = original.calendarAttendees, !attendees.isEmpty {
                transcript.providerData["momentus_attendees"] = attendees.joined(separator: ",")
            }

            // Keep the existing transcript and summary persisted until the whole
            // upgrade succeeds, so an app termination cannot destroy good notes.
            var progress = original
            progress.processingState = .summarizing
            update(progress)

            let summary = try await ServiceFactory.makeSummaryService(for: .bestQuality)
                .summarize(transcript: transcript, recordingId: original.id)
            progress.processingState = .preparingNotes
            update(progress)

            var upgraded = original
            upgraded.transcript = transcript
            upgraded.summary = summary
            if original.titleWasEditedByUser != true,
               let suggestedTitle = summary.suggestedTitle {
                upgraded.title = suggestedTitle
            }

            try await Task.sleep(for: .milliseconds(350))
            upgraded.mode = .bestQuality
            upgraded.processingState = .completed
            upgraded.processingError = nil
            update(upgraded)
            HapticStyle.success.trigger()
            NotificationCenter.default.post(
                name: .recordingProcessingCompleted,
                object: nil,
                userInfo: ["recordingId": original.id]
            )
        } catch {
            var restored = original
            restored.processingState = original.summary == nil ? .failed : .completed
            restored.processingError = "Best Quality reprocessing failed: \(error.localizedDescription)"
            update(restored)
            print("[Best Quality Reprocess] failed \(original.id): \(error)")
        }
    }

    private func performProcessingRetry(recordingID: UUID, userInitiated: Bool) async {
        defer {
            processingRecordingIDs.remove(recordingID)
            summaryModeOverrides.removeValue(forKey: recordingID)
        }
        do {
            if userInitiated, let recording = recording(for: recordingID) {
                let effectiveMode = summaryModeOverrides[recordingID] ?? recording.mode
                // Regeneration from an existing transcript does not run Whisper.
                // Request scarce background GPU access only for private, on-device
                // transcription; CPU/network are included in the default resource.
                let requiresGPU = recording.transcript == nil && effectiveMode != .bestQuality
                try await ContinuedProcessingManager.shared.run(
                    recordingID: recordingID,
                    title: recording.title,
                    requiresGPU: requiresGPU,
                    onFailure: { [weak self] error in
                        guard let self, var failed = self.recording(for: recordingID) else { return }
                        let failedStage = failed.processingState
                        if let providerError = error as? AssemblyAIError,
                           providerError.invalidatesTranscriptionCheckpoint {
                            failed.transcriptionJobID = nil
                            failed.transcriptionJobCreatedAt = nil
                        }
                        failed.processingState = .failed
                        failed.processingError = error is CancellationError
                            ? Self.interruptedProcessingMessage
                            : Self.failureMessage(stage: failedStage, error: error)
                        self.update(failed)
                    }
                ) { reporter in
                    try await self.performProcessingRetryBody(
                        recordingID: recordingID,
                        reporter: reporter
                    )
                }
            } else {
                try await performProcessingRetryBody(recordingID: recordingID, reporter: nil)
            }
        } catch is CancellationError {
            guard var recording = recording(for: recordingID) else { return }
            recording.processingState = .failed
            recording.processingError = Self.interruptedProcessingMessage
            update(recording)
        } catch {
            guard var recording = recording(for: recordingID) else { return }
            guard recording.processingState != .failed else { return }
            let failedStage = recording.processingState
            if let providerError = error as? AssemblyAIError,
               providerError.invalidatesTranscriptionCheckpoint {
                recording.transcriptionJobID = nil
                recording.transcriptionJobCreatedAt = nil
            }
            recording.processingState = .failed
            recording.processingError = Self.failureMessage(stage: failedStage, error: error)
            update(recording)
            print("[Retry Pipeline] failed \(recordingID): \(error)")
        }
    }

    private func performProcessingRetryBody(
        recordingID: UUID,
        reporter: ContinuedProcessingManager.Reporter?
    ) async throws {
        guard var recording = recording(for: recordingID) else { return }
        let transcript: Transcript
        if let existingTranscript = recording.transcript {
            transcript = existingTranscript
        } else {
            guard let audioFileID = recording.audioFileID,
                  audioIsPlayable(audioFileID)
            else { throw RecordingProcessingRetryError.audioUnavailable }

            let service = ServiceFactory.makeTranscriptionService(for: recording.mode)
            var generated: Transcript
            if let resumable = service as? any ResumableTranscriptionService {
                let jobID: String
                if let checkpoint = recording.transcriptionJobID,
                   recording.hasUsableTranscriptionCheckpoint {
                    jobID = checkpoint
                    print("[Retry Pipeline] resuming transcription job \(jobID)")
                } else {
                    if recording.transcriptionJobID != nil {
                        print("[Retry Pipeline] discarding stale transcription checkpoint")
                        recording.transcriptionJobID = nil
                        recording.transcriptionJobCreatedAt = nil
                    }
                    recording.processingState = .uploading
                    recording.processingDetail = "Starting secure upload"
                    recording.processingProgress = 0
                    update(recording)
                    reporter?.update(completed: 5, subtitle: recording.processingDetail!)
                    jobID = try await resumable.createTranscription(
                        audioFileID: audioFileID,
                        recordingId: recording.id,
                        uploadProgress: { [weak self] progress in
                            guard let self, var current = self.recording(for: recordingID) else { return }
                            current.processingState = .uploading
                            current.processingDetail = progress.displayText
                            current.processingProgress = progress.fraction
                            self.update(current)
                            let range: ClosedRange<Double> = progress.stage == .preparing
                                ? 5...15
                                : 15...30
                            let systemProgress = range.lowerBound
                                + progress.fraction * (range.upperBound - range.lowerBound)
                            reporter?.update(completed: Int64(systemProgress), subtitle: progress.displayText)
                        }
                    )
                    recording.transcriptionJobID = jobID
                    recording.transcriptionJobCreatedAt = Date()
                    update(recording)
                    print("[Retry Pipeline] checkpointed transcription job \(jobID)")
                }
                recording.processingState = .transcribing
                recording.processingDetail = "Audio uploaded — transcription in progress"
                recording.processingProgress = nil
                update(recording)
                reporter?.update(completed: 30, subtitle: recording.processingDetail!)
                generated = try await resumable.awaitTranscription(
                    id: jobID,
                    recordingId: recording.id,
                    statusUpdate: { [weak self] detail in
                        guard let self, var current = self.recording(for: recordingID) else { return }
                        current.processingState = .transcribing
                        current.processingDetail = detail
                        self.update(current)
                        reporter?.advance(upTo: 64, subtitle: detail)
                    }
                )
            } else {
                recording.processingState = .transcribing
                recording.processingDetail = "Transcribing on device"
                recording.processingProgress = nil
                update(recording)
                reporter?.update(completed: 30, subtitle: recording.processingDetail!)
                if let progressService = service as? any ProgressReportingTranscriptionService {
                    generated = try await progressService.transcribe(
                        audioFileID: audioFileID,
                        recordingId: recording.id,
                        progress: { [weak self] progress in
                            guard let self, var current = self.recording(for: recordingID) else { return }
                            current.processingDetail = progress.displayText
                            current.processingProgress = progress.fraction
                            self.update(current)
                            reporter?.update(
                                completed: Int64(30 + progress.fraction * 35),
                                subtitle: progress.displayText
                            )
                        }
                    )
                } else {
                    generated = try await service.transcribe(
                        audioFileID: audioFileID,
                        recordingId: recording.id
                    )
                }
            }
            generated.providerData["momentus_markers"] = recording.markers
                .map { String(format: "%.1f", $0) }
                .joined(separator: ",")
            if let attendees = recording.calendarAttendees, !attendees.isEmpty {
                generated.providerData["momentus_attendees"] = attendees.joined(separator: ",")
            }
            transcript = generated
            recording.transcript = generated
            recording.transcriptionJobID = nil
            recording.transcriptionJobCreatedAt = nil
            recording.processingState = .summarizing
            recording.processingDetail = "Generating meeting notes"
            update(recording)
        }

        try Task.checkCancellation()
        reporter?.update(completed: 65, subtitle: "Generating meeting notes")
        let summaryMode = summaryModeOverrides[recordingID] ?? recording.mode
        let summaryService = ServiceFactory.makeSummaryService(for: summaryMode)
        let summary: MeetingSummary
        if let progressService = summaryService as? any ProgressReportingSummaryService {
            summary = try await progressService.summarize(
                transcript: transcript,
                recordingId: recording.id,
                progress: { [weak self] progress in
                    guard let self, var current = self.recording(for: recordingID) else { return }
                    current.processingState = .summarizing
                    current.processingDetail = progress.displayText
                    current.processingProgress = progress.fraction
                    self.update(current)
                    reporter?.update(
                        completed: Int64(65 + progress.fraction * 25),
                        subtitle: progress.displayText
                    )
                }
            )
        } else {
            summary = try await summaryService.summarize(
                transcript: transcript,
                recordingId: recording.id
            )
        }
        recording.summary = summary
        if recording.titleWasEditedByUser != true,
           let suggestedTitle = summary.suggestedTitle {
            recording.title = suggestedTitle
        }
        recording.processingState = .preparingNotes
        recording.processingDetail = "Organizing your insights"
        recording.processingProgress = nil
        update(recording)

        reporter?.update(completed: 95, subtitle: "Preparing your notes")
        try await Task.sleep(for: .milliseconds(350))
        recording.processingState = .completed
        recording.processingError = nil
        recording.processingDetail = nil
        recording.processingProgress = nil
        update(recording)
        reporter?.update(completed: 100, subtitle: "Notes ready")
        HapticStyle.success.trigger()
        NotificationCenter.default.post(
            name: .recordingProcessingCompleted,
            object: nil,
            userInfo: ["recordingId": recording.id]
        )
    }

    // MARK: - Cloud Sync

    // Pulls recordings from CloudKit that don't exist locally (from other devices).
    // Local recordings not yet in CloudKit are uploaded (e.g. created while offline).
    // For existing IDs, local version is kept — it was written here most recently.
    func syncFromCloud(forceImport: Bool = false, uploadLocalOnly: Bool = true) async {
        guard forceImport || isCloudEnabled else { return }
        guard !isSyncing, await CloudKitService.shared.isAvailable() else { return }
        isSyncing = true
        defer { isSyncing = false }

        guard let cloudRecordings = try? await CloudKitService.shared.fetchAll() else { return }

        let localIDs = Set(recordings.map(\.id))
        let cloudIDs = Set(cloudRecordings.map(\.id))

        let newFromCloud = cloudRecordings.filter { !localIDs.contains($0.id) }
        if !newFromCloud.isEmpty {
            recordings.append(contentsOf: newFromCloud)
            recordings.sort { $0.startedAt > $1.startedAt }
            persist()
        }

        var didRefreshExisting = false
        for cloudRecording in cloudRecordings where localIDs.contains(cloudRecording.id) {
            guard let idx = recordings.firstIndex(where: { $0.id == cloudRecording.id }) else { continue }
            let local = recordings[idx]
            if let deletedAt = cloudRecording.rawAudioDeletedAt,
               local.rawAudioDeletedAt == nil || local.rawAudioDeletedAt! < deletedAt {
                if let audioFileID = local.audioFileID {
                    let url = AVAudioRecorderService.recordingsDirectory.appendingPathComponent(audioFileID)
                    try? FileManager.default.removeItem(at: url)
                }
                recordings[idx].audioFileID = nil
                recordings[idx].rawAudioDeletedAt = deletedAt
                didRefreshExisting = true
            } else if localNeedsAudio(local), audioIsPlayable(cloudRecording.audioFileID) {
                recordings[idx].audioFileID = cloudRecording.audioFileID
                didRefreshExisting = true
            }
        }
        if didRefreshExisting {
            persist()
        }

        let localOnly = recordings.filter { !cloudIDs.contains($0.id) }
        if uploadLocalOnly, isCloudEnabled, !localOnly.isEmpty {
            await CloudKitService.shared.saveAll(localOnly)
        }
        await applyAudioRetentionPolicy()
    }

    func importCloudRecordingsWithRetry() async {
        for attempt in 0..<4 {
            let countBefore = recordings.count
            await syncFromCloud(forceImport: true, uploadLocalOnly: false)
            if recordings.count > countBefore { return }
            if attempt < 3 {
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // Called when the user first enables iCloud sync — uploads everything.
    func enableCloudSync() async {
        guard await CloudKitService.shared.isAvailable() else { return }
        isSyncing = true
        defer { isSyncing = false }
        await CloudKitService.shared.saveAll(recordings)
        await applyAudioRetentionPolicy()
    }

    private func cloudSave(_ recording: Recording) {
        guard isCloudEnabled else { return }
        Task { await CloudKitService.shared.save(recording) }
    }

    func applyAudioRetentionPolicy(now: Date = Date()) async {
        let rawValue = UserDefaults.standard.string(forKey: "audioRetention")
        let policy = rawValue.flatMap(AudioRetentionPolicy.init(rawValue:)) ?? .keepForever
        var expiredRecordingIDs: [UUID] = []

        for index in recordings.indices {
            let recording = recordings[index]
            guard audioIsPlayable(recording.audioFileID),
                  let expiration = policy.expirationDate(for: recording),
                  expiration <= now,
                  let audioFileID = recording.audioFileID
            else { continue }

            let url = AVAudioRecorderService.recordingsDirectory.appendingPathComponent(audioFileID)
            do {
                try FileManager.default.removeItem(at: url)
                recordings[index].audioFileID = nil
                recordings[index].rawAudioDeletedAt = now
                expiredRecordingIDs.append(recording.id)
            } catch {
                print("[Audio Retention] failed to delete \(audioFileID): \(error.localizedDescription)")
            }
        }

        if !expiredRecordingIDs.isEmpty {
            persist()
            for recordingID in expiredRecordingIDs {
                await CloudKitService.shared.deleteAudioAsset(recordingID: recordingID)
            }
        }
        scheduleAudioRetentionSweep(now: now)
    }

    func processPendingRemoteTranscriptDeletions() async {
        guard !isProcessingRemoteTranscriptDeletions else { return }
        isProcessingRemoteTranscriptDeletions = true
        defer { isProcessingRemoteTranscriptDeletions = false }

        let pending = UserDefaults.standard.stringArray(forKey: remoteTranscriptDeletionKey) ?? []
        for transcriptID in pending {
            do {
                try await AssemblyAITranscriptionService().deleteRemoteTranscript(id: transcriptID)
                var remaining = UserDefaults.standard.stringArray(forKey: remoteTranscriptDeletionKey) ?? []
                remaining.removeAll { $0 == transcriptID }
                UserDefaults.standard.set(remaining, forKey: remoteTranscriptDeletionKey)
            } catch {
                print("[AssemblyAI] delete transcript \(transcriptID) deferred: \(error.localizedDescription)")
            }
        }
    }

    private func enqueueRemoteTranscriptDeletion(_ transcriptID: String) {
        var pending = UserDefaults.standard.stringArray(forKey: remoteTranscriptDeletionKey) ?? []
        guard !pending.contains(transcriptID) else { return }
        pending.append(transcriptID)
        UserDefaults.standard.set(pending, forKey: remoteTranscriptDeletionKey)
    }

    private func scheduleAudioRetentionSweep(now: Date = Date()) {
        audioRetentionTask?.cancel()
        let rawValue = UserDefaults.standard.string(forKey: "audioRetention")
        let policy = rawValue.flatMap(AudioRetentionPolicy.init(rawValue:)) ?? .keepForever
        let nextExpiration = recordings.compactMap { recording -> Date? in
            guard audioIsPlayable(recording.audioFileID) else { return nil }
            return policy.expirationDate(for: recording)
        }.min()
        guard let nextExpiration else { return }

        let delay = max(0.1, nextExpiration.timeIntervalSince(now))
        audioRetentionTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.applyAudioRetentionPolicy()
        }
    }

    private func localNeedsAudio(_ recording: Recording) -> Bool {
        !audioIsPlayable(recording.audioFileID)
    }

    private func audioIsPlayable(_ audioFileID: String?) -> Bool {
        guard let audioFileID, !audioFileID.isEmpty else { return false }
        let url = AVAudioRecorderService.recordingsDirectory.appendingPathComponent(audioFileID)
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return fileSize >= 1024
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(recordings) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}

enum RecordingProcessingRetryError: LocalizedError {
    case audioUnavailable

    var errorDescription: String? {
        "The saved audio file is unavailable, so this recording cannot be processed again."
    }
}

enum BestQualityReprocessAvailability: Equatable {
    case available
    case processing
    case alreadyBestQuality
    case audioUnavailable
    case missingAPIKey
}

// MARK: - Mock Recording Service

final class MockRecordingService: RecordingService {
    private(set) var isRecording: Bool = false
    private var accumulatedDuration: TimeInterval = 0
    private var resumedAt: Date?
    private var currentLevel: Float = 0
    private var levelTimer: Timer?

    var recordedDuration: TimeInterval {
        accumulatedDuration + (resumedAt.map { Date().timeIntervalSince($0) } ?? 0)
    }

    func startRecording(mode: RecordingMode, source: MicSource) async throws -> UUID {
        // Simulate brief startup latency
        try await Task.sleep(for: .milliseconds(200))
        accumulatedDuration = 0
        resumedAt = Date()
        isRecording = true
        return UUID()
    }

    func stopRecording() async throws -> String {
        try await Task.sleep(for: .milliseconds(300))
        accumulateCurrentSegment()
        isRecording = false
        return "mock_audio_\(UUID().uuidString.prefix(8))"
    }

    func pauseRecording() async throws {
        try await Task.sleep(for: .milliseconds(100))
        accumulateCurrentSegment()
        isRecording = false
    }

    func resumeRecording() async throws {
        try await Task.sleep(for: .milliseconds(100))
        resumedAt = Date()
        isRecording = true
    }

    func getCurrentLevel() -> Float {
        Float.random(in: 0.1...0.95)
    }

    private func accumulateCurrentSegment() {
        if let resumedAt {
            accumulatedDuration += Date().timeIntervalSince(resumedAt)
        }
        resumedAt = nil
    }
}

// MARK: - Mock Transcription Service

final class MockTranscriptionService: TranscriptionService {
    let providerName = "Mock Transcription"
    let isOnDevice = true

    func transcribe(audioFileID: String, recordingId: UUID) async throws -> Transcript {
        // Simulate transcription time (2-4 seconds)
        try await Task.sleep(for: .seconds(Double.random(in: 2...4)))
        return MockMeetings.mobileKickoffTranscript.withNewIds(recordingId: recordingId)
    }
}

// MARK: - Mock Summary Service

final class MockSummaryService: SummaryService {
    let providerName = "Mock Summary"
    let isOnDevice = false

    func summarize(transcript: Transcript, recordingId: UUID) async throws -> MeetingSummary {
        // Simulate LLM summarization time (3-5 seconds)
        try await Task.sleep(for: .seconds(Double.random(in: 3...5)))
        return MockMeetings.mobileKickoffSummary.withNewIds(recordingId: recordingId)
    }
}

// MARK: - Mock Calendar Service

final class MockCalendarContextService: CalendarContextService {
    private let isDemoMode: Bool

    init(isDemoMode: Bool = false) {
        self.isDemoMode = isDemoMode
    }

    func getCurrentMeetings() async -> [CalendarMeeting] {
        guard isDemoMode else { return [] }
        return MockMeetings.sampleCalendarMeetings.filter(\.isHappeningNow)
    }

    func getUpcomingMeetings() async -> [CalendarMeeting] {
        guard isDemoMode else { return [] }
        return MockMeetings.sampleCalendarMeetings.filter { $0.startDate > Date() }
    }

    func requestAccess() async -> Bool { true }
}

// MARK: - Local Storage Service (UserDefaults-backed)

final class LocalStorageService: StorageService {
    private let key = "stored_recordings"

    func saveRecording(_ recording: Recording) async throws {
        var all = (try? await loadRecordings()) ?? []
        all.removeAll { $0.id == recording.id }
        all.insert(recording, at: 0)
        persist(all)
    }

    func loadRecordings() async throws -> [Recording] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Recording].self, from: data)) ?? []
    }

    func deleteRecording(id: UUID) async throws {
        var all = (try? await loadRecordings()) ?? []
        all.removeAll { $0.id == id }
        persist(all)
    }

    func updateRecording(_ recording: Recording) async throws {
        try await saveRecording(recording)
    }

    func deleteAudioFile(fileID: String) async throws {
        let url = AVAudioRecorderService.recordingsDirectory.appendingPathComponent(fileID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func persist(_ recordings: [Recording]) {
        if let data = try? JSONEncoder().encode(recordings) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: - Helpers for reusing mock data with new IDs

private extension Transcript {
    func withNewIds(recordingId: UUID) -> Transcript {
        Transcript(
            id: UUID(),
            recordingId: recordingId,
            segments: segments,
            speakers: speakers,
            language: language,
            provider: provider,
            providerData: providerData,
            createdAt: Date()
        )
    }
}

private extension MeetingSummary {
    func withNewIds(recordingId: UUID) -> MeetingSummary {
        MeetingSummary(
            id: UUID(),
            recordingId: recordingId,
            suggestedTitle: suggestedTitle,
            executiveSummary: executiveSummary,
            decisions: decisions,
            actionItems: actionItems.map { item in
                ActionItem(
                    id: UUID(), title: item.title, owner: item.owner,
                    isOwnerInferred: item.isOwnerInferred, dueDate: item.dueDate,
                    isDueDateInferred: item.isDueDateInferred, isCompleted: false,
                    confidence: item.confidence, priority: item.priority
                )
            },
            openQuestions: openQuestions,
            risks: risks,
            followUpDraft: followUpDraft,
            provider: provider,
            createdAt: Date(),
            confidenceNotes: confidenceNotes
        )
    }
}
