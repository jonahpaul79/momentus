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
    var recordings: [Recording] = []
    var isSyncing = false
    private(set) var processingRecordingIDs: Set<UUID> = []

    private var isCloudEnabled: Bool {
        UserDefaults.standard.bool(forKey: "iCloudSync")
    }

    init(loadSamples: Bool = true) {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([Recording].self, from: data),
           !saved.isEmpty {
            recordings = saved.map { stored in
                var recovered = stored
                if recovered.processingState.isInProgress {
                    recovered.processingState = .failed
                    recovered.processingError = "Processing was interrupted before it finished. Your recording is preserved and can be retried."
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
        Task { await syncFromCloud() }
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
    }

    func delete(id: UUID) {
        recordings.removeAll { $0.id == id }
        persist()
        if isCloudEnabled { Task { await CloudKitService.shared.delete(id: id) } }
    }

    func delete(_ recording: Recording) {
        recordings.removeAll { $0.id == recording.id }
        persist()
        if isCloudEnabled { Task { await CloudKitService.shared.delete(id: recording.id) } }
        guard let fileID = recording.audioFileID else { return }
        Task {
            let url = AVAudioRecorderService.recordingsDirectory.appendingPathComponent(fileID)
            try? FileManager.default.removeItem(at: url)
        }
    }

    func toggle(favorite id: UUID) {
        guard let idx = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings[idx].isFavorite.toggle()
        persist()
        cloudSave(recordings[idx])
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
    func retryProcessing(recordingID: UUID) {
        guard !processingRecordingIDs.contains(recordingID),
              var recording = recording(for: recordingID),
              canRetryProcessing(recording)
        else { return }

        processingRecordingIDs.insert(recordingID)
        recording.processingError = nil
        recording.processingState = recording.transcript == nil ? .transcribing : .summarizing
        update(recording)

        Task { [weak self] in
            await self?.performProcessingRetry(recordingID: recordingID)
        }
    }

    private func performProcessingRetry(recordingID: UUID) async {
        defer { processingRecordingIDs.remove(recordingID) }
        guard var recording = recording(for: recordingID) else { return }

        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "RetryRecordingProcessing") {
            print("[Retry Pipeline] background execution time expired")
        }
        defer {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }

        do {
            let transcript: Transcript
            if let existingTranscript = recording.transcript {
                transcript = existingTranscript
            } else {
                guard let audioFileID = recording.audioFileID,
                      audioIsPlayable(audioFileID)
                else { throw RecordingProcessingRetryError.audioUnavailable }

                var generated = try await ServiceFactory.makeTranscriptionService(for: recording.mode)
                    .transcribe(audioFileID: audioFileID, recordingId: recording.id)
                generated.providerData["momentus_markers"] = recording.markers
                    .map { String(format: "%.1f", $0) }
                    .joined(separator: ",")
                if let attendees = recording.calendarAttendees, !attendees.isEmpty {
                    generated.providerData["momentus_attendees"] = attendees.joined(separator: ",")
                }
                transcript = generated
                recording.transcript = generated
                recording.processingState = .summarizing
                update(recording)
            }

            try Task.checkCancellation()
            let summary = try await ServiceFactory.makeSummaryService(for: recording.mode)
                .summarize(transcript: transcript, recordingId: recording.id)
            recording.summary = summary
            if let suggestedTitle = summary.suggestedTitle {
                recording.title = suggestedTitle
            }
            recording.processingState = .preparingNotes
            update(recording)

            try await Task.sleep(for: .milliseconds(350))
            recording.processingState = .completed
            recording.processingError = nil
            update(recording)
            HapticStyle.success.trigger()
            NotificationCenter.default.post(
                name: .recordingProcessingCompleted,
                object: nil,
                userInfo: ["recordingId": recording.id]
            )
        } catch is CancellationError {
            recording.processingState = .failed
            recording.processingError = "Processing was interrupted. Please try again."
            update(recording)
        } catch {
            recording.processingState = .failed
            recording.processingError = error.localizedDescription
            update(recording)
            print("[Retry Pipeline] failed \(recordingID): \(error)")
        }
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
            if localNeedsAudio(local), audioIsPlayable(cloudRecording.audioFileID) {
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
    }

    private func cloudSave(_ recording: Recording) {
        guard isCloudEnabled else { return }
        Task { await CloudKitService.shared.save(recording) }
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

private enum RecordingProcessingRetryError: LocalizedError {
    case audioUnavailable

    var errorDescription: String? {
        "The saved audio file is unavailable, so this recording cannot be processed again."
    }
}

// MARK: - Mock Recording Service

final class MockRecordingService: RecordingService {
    private(set) var isRecording: Bool = false
    private var currentLevel: Float = 0
    private var levelTimer: Timer?

    func startRecording(mode: RecordingMode, source: MicSource) async throws -> UUID {
        // Simulate brief startup latency
        try await Task.sleep(for: .milliseconds(200))
        isRecording = true
        return UUID()
    }

    func stopRecording() async throws -> String {
        try await Task.sleep(for: .milliseconds(300))
        isRecording = false
        return "mock_audio_\(UUID().uuidString.prefix(8))"
    }

    func pauseRecording() async throws {
        try await Task.sleep(for: .milliseconds(100))
        isRecording = false
    }

    func resumeRecording() async throws {
        try await Task.sleep(for: .milliseconds(100))
        isRecording = true
    }

    func getCurrentLevel() -> Float {
        Float.random(in: 0.1...0.95)
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
