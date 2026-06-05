import SwiftUI
import UIKit
import AVFoundation

extension Notification.Name {
    static let recordingProcessingCompleted = Notification.Name("recordingProcessingCompleted")
    static let autoStartRecording = Notification.Name("autoStartRecording")
}

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
    var waveformLevels: [Float] = Array(repeating: 0.1, count: 24)
    var markerHighlightedBars: Set<Int> = []
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
    var suggestedSpeakers: [String] = []
    var calendarMeeting: CalendarMeeting?
    var upcomingMeetings: [CalendarMeeting] = []
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
    private var watchActionTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?

    // MARK: Init

    init(
        recordingService: any RecordingService = AVAudioRecorderService(),
        transcriptionService: any TranscriptionService = AppleSpeechTranscriptionService(),
        summaryService: any SummaryService = AppleFoundationModelsSummaryService(),
        calendarService: any CalendarContextService = (ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil || UserDefaults.standard.bool(forKey: "demoMode")) ? MockCalendarContextService(isDemoMode: true) : EventKitCalendarService()
    ) {
        self.recordingService = recordingService
        self.transcriptionService = transcriptionService
        self.summaryService = summaryService
        self.calendarService = calendarService
        PhoneWatchConnectivityService.shared.configure(
            actionHandler: { [weak self] action, timestamp, mode in
                self?.handleWatchAction(action, timestamp: timestamp, mode: mode)
            },
            fileHandler: { [weak self] audioFileID, markers, mode in
                self?.handleWatchRecording(audioFileID: audioFileID, markers: markers, mode: mode)
            }
        )
    }

    func configure(store: RecordingsStore) {
        self.store = store
        // Drain any Watch recordings that arrived before RecordViewModel was ready
        let pending = PhoneWatchConnectivityService.shared.pendingRecordings
        if !pending.isEmpty {
            PhoneWatchConnectivityService.shared.clearPendingRecordings()
            for rec in pending {
                handleWatchRecording(audioFileID: rec.audioFileID, markers: rec.markers, mode: rec.mode)
            }
        }
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
        let current = await calendarService.getCurrentMeetings()
        let upcoming = await calendarService.getUpcomingMeetings()
        upcomingMeetings = current + upcoming
        let primary = current.first ?? upcoming.first
        calendarMeeting = primary
        suggestedMeetingTitle = primary?.title
        await MeetingNotificationService.shared.scheduleReminders(for: upcoming)
    }

    // MARK: Recording Control

    func startRecording() async {
        guard state == .idle else { return }
        errorMessage = nil

        // Start loading the Whisper model in the background while audio is being captured
        // so it is ready (or nearly so) by the time stopRecording triggers transcription.
        if selectedMode == .onDevice || selectedMode == .hybrid {
            WhisperKitTranscriptionService.warmup()
        }

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
        markerHighlightedBars.insert(waveformLevels.count - 1)
    }

    func stopRecording() async {
        guard state == .recording || state == .paused else { return }
        stopTimers()
        HapticStyle.heavy.trigger()

        let recordingId = currentRecordingId ?? UUID()
        currentRecordingId = recordingId
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
            markers: markers,
            calendarAttendees: suggestedSpeakers.isEmpty ? nil : suggestedSpeakers
        )
        store?.add(recording)

        state = .processing(.savingAudio)
        processingStepIndex = 0

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                print("[Pipeline] stopping recording service")
                let audioFileID = try await recordingService.stopRecording()
                print("[Pipeline] audioFileID: \(audioFileID)")
                recording.audioFileID = audioFileID
                recording.processingState = .transcribing
                store?.update(recording)

                state = .processing(.transcribing)
                processingStepIndex = 1

                try Task.checkCancellation()

                print("[Pipeline] starting transcription")
                var transcript = try await transcriptionService.transcribe(
                    audioFileID: audioFileID,
                    recordingId: recordingId
                )
                transcript.providerData["momentus_markers"] = markers.map { String(format: "%.1f", $0) }.joined(separator: ",")
                if !suggestedSpeakers.isEmpty {
                    transcript.providerData["momentus_attendees"] = suggestedSpeakers.joined(separator: ",")
                }
                print("[Pipeline] transcription done — \(transcript.segments.count) segments")
                recording.transcript = transcript
                recording.processingState = .summarizing
                store?.update(recording)

                state = .processing(.summarizing)
                processingStepIndex = 2

                try Task.checkCancellation()

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

                if UIApplication.shared.applicationState == .background {
                    await MeetingNotificationService.shared.notifySummaryReady(
                        title: recording.title,
                        recordingId: recordingId
                    )
                }

                try await Task.sleep(for: .milliseconds(700))
                NotificationCenter.default.post(
                    name: .recordingProcessingCompleted,
                    object: nil,
                    userInfo: ["recordingId": recordingId]
                )
                try await Task.sleep(for: .milliseconds(1300))
                reset()

            } catch is CancellationError {
                // cancelProcessing() handles store cleanup and state reset
            } catch {
                recording.processingState = .failed
                // Preserve everything collected so far so the recording isn't lost.
                store?.update(recording)
                errorMessage = error.localizedDescription
                print("[Pipeline] failed: \(error)")
                state = .idle
            }
        }
        processingTask = task
        await task.value
    }

    func cancelProcessing() {
        processingTask?.cancel()
        processingTask = nil
        if let id = currentRecordingId {
            store?.delete(id: id)
        }
        HapticStyle.light.trigger()
        reset()
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
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { break }
                var newLevels = self.waveformLevels
                newLevels.removeFirst()
                newLevels.append(recordingService.getCurrentLevel())
                self.waveformLevels = newLevels
                self.markerHighlightedBars = Set(self.markerHighlightedBars.compactMap { idx in
                    let shifted = idx - 1
                    return shifted >= 0 ? shifted : nil
                })
            }
        }
    }

    // MARK: Helpers

    private func reset() {
        state = .idle
        elapsedTime = 0
        waveformLevels = Array(repeating: 0.1, count: 24)
        markerHighlightedBars = []
        markers = []
        currentRecordingId = nil
        processingStepIndex = 0
        suggestedSpeakers = []
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

    private func handleWatchRecording(audioFileID: String, markers: [TimeInterval], mode: String?) {
        let prev = watchActionTask
        watchActionTask = Task { [weak self] in
            await prev?.value
            guard let self else { return }
            await self.processWatchRecording(audioFileID: audioFileID, markers: markers, mode: mode)
        }
    }

    private func processWatchRecording(audioFileID: String, markers: [TimeInterval], mode: String?) async {
        guard let store else { return }

        let fileURL = AVAudioRecorderService.recordingsDirectory.appendingPathComponent(audioFileID)
        let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard fileSize > 1024 else {
            print("[Watch Pipeline] audio file missing or empty (\(fileSize) bytes) — aborting")
            return
        }
        print("[Watch Pipeline] audio file ready: \(audioFileID) (\(fileSize) bytes)")

        // Read actual audio duration so the recording's duration field is correct
        // and the audio player shows the right length.
        let audioDuration: TimeInterval
        if let cmDuration = try? await AVURLAsset(url: fileURL).load(.duration) {
            audioDuration = CMTimeGetSeconds(cmDuration)
        } else {
            audioDuration = 0
        }

        let recordingId = UUID()
        let recordingMode: RecordingMode = mode == "Quality" ? .bestQuality : .onDevice
        let recordingEnd = Date()
        let recordingStart = audioDuration > 0
            ? recordingEnd.addingTimeInterval(-audioDuration)
            : recordingEnd

        var recording = Recording(
            id: recordingId,
            title: titleFromTime(),
            startedAt: recordingStart,
            endedAt: recordingEnd,
            mode: recordingMode,
            micSource: .watch,
            audioFileID: audioFileID,
            processingState: .transcribing,
            markers: markers
        )
        store.add(recording)
        state = .processing(.transcribing)
        processingStepIndex = 1

        do {
            var transcript = try await transcriptionService.transcribe(
                audioFileID: audioFileID,
                recordingId: recordingId
            )
            if !markers.isEmpty {
                transcript.providerData["momentus_markers"] = markers
                    .map { String(format: "%.1f", $0) }.joined(separator: ",")
            }
            recording.transcript = transcript
            recording.processingState = .summarizing
            store.update(recording)
            state = .processing(.summarizing)
            processingStepIndex = 2

            let summary = try await summaryService.summarize(
                transcript: transcript,
                recordingId: recordingId
            )
            recording.summary = summary
            if let suggested = summary.suggestedTitle {
                recording.title = suggested
            }
            recording.processingState = .completed
            store.update(recording)

            HapticStyle.success.trigger()
            state = .idle

            PhoneWatchConnectivityService.shared.notifyWatchRecordingComplete()

            // Always notify — the app may have been woken by WatchConnectivity
            // even when the user isn't actively looking at it.
            await MeetingNotificationService.shared.notifySummaryReady(
                title: recording.title,
                recordingId: recordingId
            )

            NotificationCenter.default.post(
                name: .recordingProcessingCompleted,
                object: nil,
                userInfo: ["recordingId": recordingId]
            )
        } catch {
            recording.processingState = .failed
            store.update(recording)
            state = .idle
            print("[Watch Pipeline] failed: \(error)")
        }
    }

    private func handleWatchAction(_ action: String, timestamp: TimeInterval?, mode: String?) {
        let prev = watchActionTask
        watchActionTask = Task { [weak self] in
            await prev?.value
            guard let self else { return }
            switch action {
            case "startRecording":
                if mode == WatchRecordingMode.bestQualityRawValue { self.selectedMode = .bestQuality }
                else if mode == WatchRecordingMode.onDeviceRawValue { self.selectedMode = .onDevice }
                await self.startRecording()
            case "stopRecording":
                await self.stopRecording()
            case "pauseRecording":
                await self.pauseRecording()
            case "resumeRecording":
                await self.resumeRecording()
            case "addMarker":
                guard self.state == .recording || self.state == .paused else { return }
                self.addMarker(at: timestamp ?? self.elapsedTime)
                HapticStyle.medium.trigger()
            default:
                break
            }
        }
    }

    private enum WatchRecordingMode {
        static let onDeviceRawValue = "Private"
        static let bestQualityRawValue = "Quality"
    }
}
