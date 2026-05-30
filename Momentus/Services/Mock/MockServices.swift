import Foundation

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
    var recordings: [Recording] = []

    init(loadSamples: Bool = true) {
        if loadSamples {
            recordings = MockMeetings.sampleRecordings
        }
        // TODO: load from LocalStorageService on init for persistence
    }

    func add(_ recording: Recording) {
        recordings.insert(recording, at: 0)
    }

    func update(_ recording: Recording) {
        guard let idx = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        recordings[idx] = recording
    }

    func delete(id: UUID) {
        recordings.removeAll { $0.id == id }
    }

    func toggle(favorite id: UUID) {
        guard let idx = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings[idx].isFavorite.toggle()
    }

    func recording(for id: UUID) -> Recording? {
        recordings.first { $0.id == id }
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
        return MockMeetings.sampleCalendarMeetings.filter(\.isStartingSoon)
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
        // TODO: delete actual audio file from disk
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
