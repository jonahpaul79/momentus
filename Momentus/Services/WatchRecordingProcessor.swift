import AVFoundation
import UIKit

@MainActor
final class WatchRecordingProcessor {
    static let shared = WatchRecordingProcessor()

    private var store: RecordingsStore?
    private var processingTask: Task<Void, Never>?

    private init() {}

    func configure(store: RecordingsStore) {
        self.store = store
        drainPendingRecordings()
    }

    func enqueue(audioFileID: String, markers: [TimeInterval], mode: String?) {
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
        PhoneWatchConnectivityService.shared.clearPendingRecordings()
        print("[Watch Pipeline] draining \(pending.count) queued recording(s)")
        for rec in pending {
            enqueue(audioFileID: rec.audioFileID, markers: rec.markers, mode: rec.mode)
        }
    }

    private func process(audioFileID: String, markers: [TimeInterval], mode: String?) async {
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
