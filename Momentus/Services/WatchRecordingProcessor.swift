import AVFoundation
import UIKit

@MainActor
final class WatchRecordingProcessor {
    static let shared = WatchRecordingProcessor()

    private var store: RecordingsStore?
    private var processingTask: Task<Void, Never>?
    private var queuedAudioFileIDs: Set<String> = []

    private init() {}

    func configure(store: RecordingsStore) {
        self.store = store
        drainPendingRecordings()
    }

    func waitForCurrentProcessing() async {
        await processingTask?.value
    }

    func importCloudProcessedRecording(_ message: [String: Any]) {
        if store == nil {
            store = RecordingsStore(loadSamples: false)
            print("[Watch Pipeline] created background store for cloud import")
        }
        guard let store else { return }

        let recordingId = (message["recordingId"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        let transcriptText = (message["transcriptText"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !transcriptText.isEmpty else { return }

        let summaryText = (message["summaryText"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (message["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let startedAt = Date(timeIntervalSince1970: message["startedAt"] as? TimeInterval ?? Date().timeIntervalSince1970)
        let endedAt = Date(timeIntervalSince1970: message["endedAt"] as? TimeInterval ?? Date().timeIntervalSince1970)
        let duration = max(1, endedAt.timeIntervalSince(startedAt))
        let markers = ((message["markers"] as? String) ?? "")
            .split(separator: ",")
            .compactMap { TimeInterval($0) }

        let speaker = Speaker(id: UUID(), name: "Speaker 1", isNameInferred: true, colorHex: "#6366F1")
        let transcript = Transcript(
            id: UUID(),
            recordingId: recordingId,
            segments: [
                TranscriptSegment(
                    id: UUID(),
                    text: transcriptText,
                    startTime: 0,
                    endTime: duration,
                    speakerId: speaker.id,
                    confidence: 0.9
                )
            ],
            speakers: [speaker],
            language: "en",
            provider: "AssemblyAI (Watch Cloud)",
            createdAt: Date()
        )

        let summary = MeetingSummary(
            recordingId: recordingId,
            suggestedTitle: title?.isEmpty == false ? title : nil,
            executiveSummary: summaryText?.isEmpty == false ? summaryText! : transcriptText,
            followUpDraft: "Hi team, following up on our recent meeting.",
            provider: summaryText?.isEmpty == false ? "AssemblyAI LeMUR (Watch Cloud)" : "Watch Cloud Transcript",
            confidenceNotes: ["Processed directly from Apple Watch because the iPhone app was not reachable."]
        )

        let recording = Recording(
            id: recordingId,
            title: title?.isEmpty == false ? title! : titleFromTime(),
            startedAt: startedAt,
            endedAt: endedAt,
            mode: .bestQuality,
            micSource: .watch,
            audioFileID: "",
            processingState: .completed,
            transcript: transcript,
            summary: summary,
            markers: markers
        )

        store.add(recording)
        NotificationCenter.default.post(
            name: .recordingProcessingCompleted,
            object: nil,
            userInfo: ["recordingId": recordingId]
        )
    }

    func enqueue(audioFileID: String, markers: [TimeInterval], mode: String?) {
        guard queuedAudioFileIDs.insert(audioFileID).inserted else {
            print("[Watch Pipeline] already queued \(audioFileID)")
            return
        }

        if store == nil {
            store = RecordingsStore(loadSamples: false)
            print("[Watch Pipeline] created background store")
        }

        let previous = processingTask
        processingTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.process(audioFileID: audioFileID, markers: markers, mode: mode)
        }
    }

    private func drainPendingRecordings() {
        let pending = PhoneWatchConnectivityService.shared.pendingRecordings
        guard !pending.isEmpty else { return }
        print("[Watch Pipeline] draining \(pending.count) queued recording(s)")
        for rec in pending {
            enqueue(audioFileID: rec.audioFileID, markers: rec.markers, mode: rec.mode)
        }
    }

    private func process(audioFileID: String, markers: [TimeInterval], mode: String?) async {
        defer {
            queuedAudioFileIDs.remove(audioFileID)
            PhoneWatchConnectivityService.shared.removePendingRecording(audioFileID: audioFileID)
        }

        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ProcessWatchRecording") {
            print("[Watch Pipeline] background task expiring")
            PhoneWatchConnectivityService.shared.notifyWatchRecordingNeedsPhoneWake()
        }
        defer {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }

        guard let store else { return }

        let fileURL = AVAudioRecorderService.recordingsDirectory.appendingPathComponent(audioFileID)
        let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard fileSize > 1024 else {
            print("[Watch Pipeline] audio file missing or empty (\(fileSize) bytes) - aborting")
            PhoneWatchConnectivityService.shared.notifyWatchRecordingFailed()
            return
        }
        print("[Watch Pipeline] processing \(audioFileID) (\(fileSize) bytes)")

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
        PhoneWatchConnectivityService.shared.notifyWatchRecordingProcessing()

        let transcriptionService = ServiceFactory.makeTranscriptionService(for: recordingMode)
        let summaryService = ServiceFactory.makeSummaryService(for: recordingMode)

        do {
            print("[Watch Pipeline] transcribing \(audioFileID)")
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

            print("[Watch Pipeline] summarizing \(audioFileID)")
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

            print("[Watch Pipeline] completed \(audioFileID)")
            PhoneWatchConnectivityService.shared.notifyWatchRecordingComplete()
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
            print("[Watch Pipeline] failed \(audioFileID): \(error)")
            PhoneWatchConnectivityService.shared.notifyWatchRecordingFailed()
        }
    }

    private func titleFromTime() -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d h:mm a"
        return "Recording - \(f.string(from: Date()))"
    }
}
