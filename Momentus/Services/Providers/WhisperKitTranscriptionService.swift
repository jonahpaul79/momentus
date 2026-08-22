@preconcurrency import WhisperKit
import AVFoundation
import Foundation

/// On-device transcription using OpenAI's Whisper model via WhisperKit.
/// Audio never leaves the device. The model (~250 MB) is downloaded from
/// Hugging Face on first use and cached in the app container indefinitely.
///
/// Call `warmup()` while the user is recording so the model is ready
/// before `transcribe` is awaited.
final class WhisperKitTranscriptionService: ProgressReportingTranscriptionService {
    let providerName = "Whisper (On-Device)"
    let isOnDevice = true

    // small.en: ~250 MB, good accuracy for English meeting audio.
    // Swap to "openai_whisper-base.en" (~75 MB) for faster load / lower quality.
    static let modelName = "openai_whisper-small.en"

    // WhisperKit isn't Sendable; nonisolated(unsafe) is safe here because
    // the app uses SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor — all access
    // is serialised on the main thread.
    nonisolated(unsafe) private static var pipeline: WhisperKit?
    nonisolated(unsafe) private static var isLoading = false
    nonisolated(unsafe) private static var waiters: [CheckedContinuation<Void, Never>] = []

    // MARK: - TranscriptionService

    func transcribe(audioFileID: String, recordingId: UUID) async throws -> Transcript {
        try await transcribe(audioFileID: audioFileID, recordingId: recordingId, progress: nil)
    }

    func transcribe(
        audioFileID: String,
        recordingId: UUID,
        progress statusUpdate: (@MainActor @Sendable (OnDeviceTranscriptionProgress) -> Void)?
    ) async throws -> Transcript {
        await Self.ensureLoaded()

        guard let pipeline = Self.pipeline else {
            print("[WhisperKit] pipeline unavailable — returning empty transcript")
            return emptyTranscript(recordingId: recordingId)
        }

        let fileURL = AVAudioRecorderService.recordingsDirectory.appendingPathComponent(audioFileID)
        print("[WhisperKit] transcribing \(audioFileID)")

        let asset = AVURLAsset(url: fileURL)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let progressGate = WhisperProgressGate()
        let callback: TranscriptionCallback?
        if let statusUpdate {
            let notifier = WhisperProgressNotifier(callback: statusUpdate)
            callback = { @Sendable transcriptionProgress in
                let windowID = transcriptionProgress.windowId
                guard progressGate.shouldReport(windowID: windowID) else {
                    return !Task.isCancelled
                }
                // Whisper processes roughly 30-second windows. Reporting completed
                // windows gives long recordings useful progress without writing on
                // every decoded token.
                let processedSeconds = Double(windowID + 1) * 30
                let fraction = duration > 0 ? min(0.99, processedSeconds / duration) : 0
                notifier.send(OnDeviceTranscriptionProgress(fraction: fraction))
                return !Task.isCancelled
            }
        } else {
            callback = nil
        }
        let results = try await pipeline.transcribe(audioPath: fileURL.path, callback: callback)
        let result = results.first
        statusUpdate?(OnDeviceTranscriptionProgress(fraction: 1))
        print("[WhisperKit] done — \(result?.segments.count ?? 0) segments")
        return buildTranscript(from: result, recordingId: recordingId)
    }

    // MARK: - Warmup

    /// Starts downloading/loading the model in the background. Call this when
    /// recording begins so the model is ready by the time recording stops.
    static func warmup() {
        guard pipeline == nil, !isLoading else { return }
        Task { await ensureLoaded() }
    }

    // MARK: - Pipeline loading

    /// Ensures the pipeline is loaded, coalescing concurrent callers so the
    /// model is only downloaded/initialised once.
    private static func ensureLoaded() async {
        if pipeline != nil { return }

        if isLoading {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                waiters.append(cont)
            }
            return
        }

        isLoading = true
        print("[WhisperKit] loading model: \(modelName)")

        do {
            let pipe = try await WhisperKit(model: modelName)
            pipeline = pipe
            print("[WhisperKit] model ready")
        } catch {
            print("[WhisperKit] failed to load model: \(error)")
        }

        isLoading = false
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }

    // MARK: - Result conversion

    private func buildTranscript(from result: TranscriptionResult?, recordingId: UUID) -> Transcript {
        let speaker = Speaker(id: UUID(), name: "Speaker 1", isNameInferred: true, colorHex: "#6366F1")

        let segments: [TranscriptSegment] = (result?.segments ?? []).compactMap { seg in
            guard let text = TranscriptTextSanitizer.cleaned(seg.text) else { return nil }
            // avgLogprob is in (-∞, 0]; exp maps it to (0, 1].
            let confidence = Float(max(0.0, min(1.0, exp(Double(seg.avgLogprob)))))
            return TranscriptSegment(
                id: UUID(),
                text: text,
                startTime: Double(seg.start),
                endTime: Double(seg.end),
                speakerId: speaker.id,
                confidence: confidence
            )
        }

        return Transcript(
            id: UUID(),
            recordingId: recordingId,
            segments: segments,
            speakers: segments.isEmpty ? [] : [speaker],
            language: result?.language ?? "en",
            provider: providerName,
            createdAt: Date()
        )
    }

    private func emptyTranscript(recordingId: UUID) -> Transcript {
        Transcript(
            id: UUID(),
            recordingId: recordingId,
            segments: [],
            speakers: [],
            language: "en",
            provider: providerName,
            createdAt: Date()
        )
    }
}

private final class WhisperProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var lastWindowID = -1

    nonisolated func shouldReport(windowID: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard windowID != lastWindowID else { return false }
        lastWindowID = windowID
        return true
    }
}

private final class WhisperProgressNotifier: @unchecked Sendable {
    private let callback: @MainActor @Sendable (OnDeviceTranscriptionProgress) -> Void

    init(callback: @escaping @MainActor @Sendable (OnDeviceTranscriptionProgress) -> Void) {
        self.callback = callback
    }

    nonisolated func send(_ progress: OnDeviceTranscriptionProgress) {
        Task { @MainActor [callback] in callback(progress) }
    }
}
