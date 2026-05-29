import SwiftUI

/// Drives the entire record → process → save flow.
///
/// **Lifecycle:** created as `@State` in `RecordHomeView`, receives `RecordingsStore`
/// via `configure(store:)` in `.task {}` (can't inject at init time since the store
/// comes from environment which isn't available during `@State` initialization).
///
/// **Processing pipeline** (in `stopRecording()`):
/// ```
/// RecordingService.stopRecording()       → audioFileID
/// TranscriptionService.transcribe(...)   → Transcript
/// SummaryService.summarize(...)          → MeetingSummary
/// store.update(recording)                → triggers Notes list refresh
/// ```
/// Each step writes partial state back to `RecordingsStore` so the Notes list
/// shows processing progress while work is in flight.
///
/// **Swapping providers:** change the defaults in `init(recordingService:transcriptionService:summaryService:)`.
@Observable final class RecordViewModel {

    // MARK: State

    enum State: Equatable {
        case idle
        case recording
        case paused
        case processing(ProcessingState)
        case completed
    }

    var state: State = .idle
    var elapsedTime: TimeInterval = 0
    var waveformLevels: [Float] = Array(repeating: 0.1, count: 40)
    var selectedMode: RecordingMode = .onDevice
    var selectedMicSource: MicSource = .iPhone
    var processingStepIndex: Int = 0
    var errorMessage: String?
    var currentRecordingId: UUID?
    var suggestedMeetingTitle: String?
    var calendarMeeting: CalendarMeeting?

    var isActive: Bool {
        switch state {
        case .recording, .paused, .processing: return true
        default: return false
        }
    }

    // MARK: Dependencies

    private var store: RecordingsStore?
    private let recordingService: any RecordingService
    private let transcriptionService: any TranscriptionService
    private let summaryService: any SummaryService
    private let calendarService: any CalendarContextService

    private var timerTask: Task<Void, Never>?
    private var waveformTask: Task<Void, Never>?

    // MARK: Init

    init(
        recordingService: any RecordingService = MockRecordingService(),
        transcriptionService: any TranscriptionService = MockTranscriptionService(),
        summaryService: any SummaryService = MockSummaryService(),
        calendarService: any CalendarContextService = MockCalendarContextService()
    ) {
        self.recordingService = recordingService
        self.transcriptionService = transcriptionService
        self.summaryService = summaryService
        self.calendarService = calendarService
    }

    func configure(store: RecordingsStore) {
        self.store = store
    }

    // MARK: Calendar Context

    func loadCalendarContext() async {
        let meetings = await calendarService.getCurrentMeetings()
        if let meeting = meetings.first {
            calendarMeeting = meeting
            suggestedMeetingTitle = meeting.title
        } else {
            let upcoming = await calendarService.getUpcomingMeetings()
            calendarMeeting = upcoming.first
            suggestedMeetingTitle = upcoming.first?.title
        }
    }

    // MARK: Recording Control

    func startRecording() async {
        guard state == .idle else { return }
        errorMessage = nil

        do {
            let id = try await recordingService.startRecording(mode: selectedMode, source: selectedMicSource)
            currentRecordingId = id
            state = .recording
            elapsedTime = 0
            HapticStyle.medium.trigger()
            startTimers()
        } catch {
            errorMessage = "Could not start recording: \(error.localizedDescription)"
        }
    }

    func pauseRecording() async {
        guard state == .recording else { return }
        do {
            try await recordingService.pauseRecording()
            state = .paused
            stopWaveformTimer()
            HapticStyle.light.trigger()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resumeRecording() async {
        guard state == .paused else { return }
        do {
            try await recordingService.resumeRecording()
            state = .recording
            startWaveformTimer()
            HapticStyle.light.trigger()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addMarker() {
        HapticStyle.medium.trigger()
    }

    func stopRecording() async {
        guard state == .recording || state == .paused else { return }
        stopTimers()
        HapticStyle.heavy.trigger()

        let recordingId = currentRecordingId ?? UUID()
        let title = suggestedMeetingTitle ?? titleFromTime()
        let recordingStart = Date().addingTimeInterval(-elapsedTime)

        var recording = Recording(
            id: recordingId,
            title: title,
            startedAt: recordingStart,
            endedAt: Date(),
            mode: selectedMode,
            micSource: selectedMicSource,
            processingState: .savingAudio
        )
        store?.add(recording)

        // Processing pipeline
        state = .processing(.savingAudio)
        processingStepIndex = 0

        do {
            let audioFileID = try await recordingService.stopRecording()
            recording.audioFileID = audioFileID
            recording.processingState = .transcribing
            store?.update(recording)

            state = .processing(.transcribing)
            processingStepIndex = 1

            let transcript = try await transcriptionService.transcribe(
                audioFileID: audioFileID,
                recordingId: recordingId
            )
            recording.transcript = transcript
            recording.processingState = .summarizing
            store?.update(recording)

            state = .processing(.summarizing)
            processingStepIndex = 2

            let summary = try await summaryService.summarize(transcript: transcript, recordingId: recordingId)
            recording.summary = summary
            if let suggested = summary.suggestedTitle {
                recording.title = suggested
            }
            recording.processingState = .preparingNotes
            store?.update(recording)

            state = .processing(.preparingNotes)
            processingStepIndex = 3

            try await Task.sleep(for: .milliseconds(900))

            recording.processingState = .completed
            store?.update(recording)

            HapticStyle.success.trigger()
            state = .completed

            try await Task.sleep(for: .seconds(2))
            reset()

        } catch {
            recording.processingState = .failed
            store?.update(recording)
            errorMessage = error.localizedDescription
            state = .idle
        }
    }

    // MARK: Timers

    private func startTimers() {
        startMainTimer()
        startWaveformTimer()
    }

    private func stopTimers() {
        timerTask?.cancel()
        waveformTask?.cancel()
        timerTask = nil
        waveformTask = nil
    }

    private func stopWaveformTimer() {
        waveformTask?.cancel()
        waveformTask = nil
    }

    private func startMainTimer() {
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { break }
                self?.elapsedTime += 0.1
            }
        }
    }

    private func startWaveformTimer() {
        waveformTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled, let self else { break }
                var newLevels = self.waveformLevels
                newLevels.removeFirst()
                newLevels.append(recordingService.getCurrentLevel())
                self.waveformLevels = newLevels
            }
        }
    }

    // MARK: Helpers

    private func reset() {
        state = .idle
        elapsedTime = 0
        waveformLevels = Array(repeating: 0.1, count: 40)
        currentRecordingId = nil
        processingStepIndex = 0
    }

    private func titleFromTime() -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d h:mm a"
        return "Recording — \(f.string(from: Date()))"
    }
}
