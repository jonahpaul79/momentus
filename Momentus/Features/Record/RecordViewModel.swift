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
    var waveformLevels: [Float] = Array(repeating: 0.1, count: 20)
    var selectedMode: RecordingMode = {
        guard let raw = UserDefaults.standard.string(forKey: "defaultRecordingMode"),
              let mode = RecordingMode(rawValue: raw) else { return .onDevice }
        return mode
    }() {
        didSet { UserDefaults.standard.set(selectedMode.rawValue, forKey: "defaultRecordingMode") }
    }
    var selectedMicSource: MicSource = .iPhone
    var processingStepIndex: Int = 0
    var errorMessage: String?
    var currentRecordingId: UUID?
    var suggestedMeetingTitle: String?
    var calendarMeeting: CalendarMeeting?
    var markers: [TimeInterval] = []

    var isActive: Bool {
        switch state {
        case .recording, .paused, .processing: return true
        default: return false
        }
    }

    // MARK: Dependencies

    private var store: RecordingsStore?
    private let recordingService: any RecordingService
    private var transcriptionService: any TranscriptionService
    private var summaryService: any SummaryService
    private let calendarService: any CalendarContextService

    private var timerTask: Task<Void, Never>?
    private var waveformTask: Task<Void, Never>?

    // MARK: Init

    init(
        recordingService: any RecordingService = AVAudioRecorderService(),
        transcriptionService: any TranscriptionService = AppleSpeechTranscriptionService(),
        summaryService: any SummaryService = AppleFoundationModelsSummaryService(),
        calendarService: any CalendarContextService = MockCalendarContextService(isDemoMode: UserDefaults.standard.bool(forKey: "demoMode"))
    ) {
        self.recordingService = recordingService
        self.transcriptionService = transcriptionService
        self.summaryService = summaryService
        self.calendarService = calendarService
        PhoneWatchConnectivityService.shared.configure { [weak self] action, timestamp, mode in
            self?.handleWatchAction(action, timestamp: timestamp, mode: mode)
        }
    }

    func configure(store: RecordingsStore) {
        self.store = store
    }

    /// Swaps in services built by ServiceFactory for the given mode.
    /// Call this from RecordHomeView whenever the mode changes.
    func configure(transcriptionService: any TranscriptionService, summaryService: any SummaryService) {
        self.transcriptionService = transcriptionService
        self.summaryService = summaryService
        print("[RecordViewModel] services updated — transcription: \(transcriptionService.providerName), summary: \(summaryService.providerName)")
    }

    /// Display name of the active summary provider (e.g. "Claude Sonnet" or "AssemblyAI LeMUR").
    var summaryProviderName: String { summaryService.providerName }

    /// True when Best Quality mode is selected but no AssemblyAI key is configured
    /// (transcription is the hard requirement — without it, Best Quality is effectively mock).
    var isMissingTranscriptionKey: Bool {
        selectedMode == .bestQuality && !ServiceFactory.isConfigured(for: .bestQuality)
    }

    /// True when Best Quality is selected, AssemblyAI transcription is configured,
    /// but no Claude key is present — so summary will use AssemblyAI LeMUR instead.
    var isUsingSummaryFallback: Bool {
        guard selectedMode == .bestQuality else { return false }
        let hasAssemblyAI = ServiceFactory.isConfigured(for: .bestQuality)
        let hasClaude = !(KeychainService.retrieve(.anthropicAPIKey) ?? "").isEmpty
        return hasAssemblyAI && !hasClaude
    }

    /// Backwards-compat alias used by RecordHomeView.
    var isMissingAPIKey: Bool { isMissingTranscriptionKey }

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
            markers = []
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
        guard state == .recording || state == .paused else { return }
        let marker = max(0, elapsedTime)
        addMarker(at: marker)
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
            processingState: .savingAudio,
            markers: markers
        )
        store?.add(recording)

        // Processing pipeline
        state = .processing(.savingAudio)
        processingStepIndex = 0

        do {
            print("[Pipeline] stopping recording service")
            let audioFileID = try await recordingService.stopRecording()
            print("[Pipeline] audioFileID: \(audioFileID)")
            recording.audioFileID = audioFileID
            recording.processingState = .transcribing
            store?.update(recording)

            state = .processing(.transcribing)
            processingStepIndex = 1

            print("[Pipeline] starting transcription")
            var transcript = try await transcriptionService.transcribe(
                audioFileID: audioFileID,
                recordingId: recordingId
            )
            transcript.providerData["momentus_markers"] = markers.map { String(format: "%.1f", $0) }.joined(separator: ",")
            print("[Pipeline] transcription done — \(transcript.segments.count) segments")
            recording.transcript = transcript
            recording.processingState = .summarizing
            store?.update(recording)

            state = .processing(.summarizing)
            processingStepIndex = 2

            print("[Pipeline] starting summarization")
            let summary = try await summaryService.summarize(transcript: transcript, recordingId: recordingId)
            print("[Pipeline] summarization done")
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
            // Preserve everything collected so far so the recording isn't lost.
            store?.update(recording)
            errorMessage = error.localizedDescription
            print("[Pipeline] failed: \(error)")
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
                try? await Task.sleep(for: .milliseconds(200))
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
        waveformLevels = Array(repeating: 0.1, count: 20)
        markers = []
        currentRecordingId = nil
        processingStepIndex = 0
    }

    private func titleFromTime() -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d h:mm a"
        return "Recording — \(f.string(from: Date()))"
    }

    private func addMarker(at timestamp: TimeInterval) {
        let marker = max(0, timestamp)
        guard markers.last.map({ abs($0 - marker) > 1.0 }) ?? true else { return }
        markers.append(marker)
    }

    private func handleWatchAction(_ action: String, timestamp: TimeInterval?, mode: String?) {
        switch action {
        case "startRecording":
            if mode == WatchRecordingMode.bestQualityRawValue {
                selectedMode = .bestQuality
            } else if mode == WatchRecordingMode.onDeviceRawValue {
                selectedMode = .onDevice
            }
            Task { await startRecording() }
        case "stopRecording":
            Task { await stopRecording() }
        case "pauseRecording":
            Task { await pauseRecording() }
        case "resumeRecording":
            Task { await resumeRecording() }
        case "addMarker":
            guard state == .recording || state == .paused else { return }
            addMarker(at: timestamp ?? elapsedTime)
            HapticStyle.medium.trigger()
        default:
            break
        }
    }

    private enum WatchRecordingMode {
        static let onDeviceRawValue = "Private"
        static let bestQualityRawValue = "Quality"
    }
}
