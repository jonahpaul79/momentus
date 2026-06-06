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

        let watchSummary = message["summary"] as? [String: Any]
        let legacySummaryText = (message["summaryText"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = cleanedString(watchSummary?["title"] as? String)
            ?? cleanedString(message["title"] as? String)
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

        let summary = watchSummary.map {
            buildWatchCloudSummary(recordingId: recordingId, payload: $0, legacySummaryText: nil)
        } ?? legacySummaryText.flatMap {
            buildLegacyWatchCloudSummary(recordingId: recordingId, summaryText: $0, transcriptText: transcriptText)
        }

        var recording = Recording(
            id: recordingId,
            title: summary?.suggestedTitle ?? title ?? titleFromTime(),
            startedAt: startedAt,
            endedAt: endedAt,
            mode: .bestQuality,
            micSource: .watch,
            audioFileID: "",
            processingState: summary == nil ? .summarizing : .completed,
            transcript: transcript,
            summary: summary,
            markers: markers
        )

        store.add(recording)

        if summary == nil {
            Task { [weak self] in
                await self?.summarizeImportedWatchRecording(recording, transcript: transcript)
            }
        } else {
            NotificationCenter.default.post(
                name: .recordingProcessingCompleted,
                object: nil,
                userInfo: ["recordingId": recordingId]
            )
        }
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

    private func summarizeImportedWatchRecording(_ recording: Recording, transcript: Transcript) async {
        guard let store else { return }
        var recording = recording
        do {
            let summary = try await ServiceFactory.makeSummaryService(for: .bestQuality).summarize(
                transcript: transcript,
                recordingId: recording.id
            )
            recording.summary = summary
            if let suggested = summary.suggestedTitle {
                recording.title = suggested
            }
            recording.processingState = .completed
            store.update(recording)
            NotificationCenter.default.post(
                name: .recordingProcessingCompleted,
                object: nil,
                userInfo: ["recordingId": recording.id]
            )
        } catch {
            print("[Watch Pipeline] phone summary failed for cloud transcript: \(error)")
            recording.summary = MeetingSummary(
                recordingId: recording.id,
                executiveSummary: "Summary could not be generated yet. The transcript is available.",
                followUpDraft: "Hi team, following up on our recent meeting.",
                provider: "Watch Cloud Transcript",
                confidenceNotes: [
                    "Transcript was processed directly from Apple Watch.",
                    "Phone summary generation failed: \(error.localizedDescription)"
                ]
            )
            recording.processingState = .completed
            store.update(recording)
            NotificationCenter.default.post(
                name: .recordingProcessingCompleted,
                object: nil,
                userInfo: ["recordingId": recording.id]
            )
        }
    }

    private func buildWatchCloudSummary(
        recordingId: UUID,
        payload: [String: Any],
        legacySummaryText: String?
    ) -> MeetingSummary {
        let title = cleanedString(payload["title"] as? String)
        let executiveSummary = cleanedString(payload["executiveSummary"] as? String)
            ?? cleanedString(legacySummaryText)
            ?? "Summary could not be generated yet. The transcript is available."

        let decisions = (payload["decisions"] as? [String] ?? []).compactMap {
            MeetingSummarySanitizer.cleanDecision(text: $0, context: nil, confidence: 0.85)
        }
        let actionItems = (payload["actionItems"] as? [[String: String]] ?? []).compactMap { item in
            MeetingSummarySanitizer.cleanActionItem(
                title: item["task"] ?? "",
                owner: item["owner"],
                isOwnerInferred: false,
                confidence: 0.85,
                priority: .medium
            )
        }
        let openQuestions = (payload["openQuestions"] as? [String] ?? []).compactMap {
            MeetingSummarySanitizer.cleanOpenQuestion(text: $0, owner: nil, priority: .medium)
        }
        let followUp = cleanedString(payload["followUp"] as? String)
            ?? "Hi team, following up on our recent meeting."

        var confidenceNotes = ["Processed directly from Apple Watch because the iPhone app was not reachable."]

        return MeetingSummary(
            recordingId: recordingId,
            suggestedTitle: title,
            executiveSummary: executiveSummary,
            decisions: decisions,
            actionItems: actionItems,
            openQuestions: openQuestions,
            followUpDraft: followUp,
            provider: payload == nil ? "Watch Cloud Transcript" : "AssemblyAI LeMUR (Watch Cloud)",
            confidenceNotes: confidenceNotes
        )
    }

    private func buildLegacyWatchCloudSummary(
        recordingId: UUID,
        summaryText: String,
        transcriptText: String
    ) -> MeetingSummary? {
        guard let summary = cleanedLegacySummary(summaryText, transcriptText: transcriptText) else { return nil }
        return buildWatchCloudSummary(
            recordingId: recordingId,
            payload: ["executiveSummary": summary],
            legacySummaryText: summary
        )
    }

    private func cleanedLegacySummary(_ summary: String, transcriptText: String) -> String? {
        guard let summary = cleanedString(summary) else { return nil }
        let transcript = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard summary != transcript else { return nil }
        guard summary.count < transcript.count / 2 || transcript.count < 500 else { return nil }
        return summary
    }

    private func cleanedString(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned.lowercased() == "null" ? nil : cleaned
    }
}
