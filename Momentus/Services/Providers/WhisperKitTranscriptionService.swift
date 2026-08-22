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
    /// Keep each decode and each resume checkpoint bounded so multi-hour
    /// recordings neither exhaust memory nor restart from zero after interruption.
    private static let diskChunkDuration: TimeInterval = 5 * 60

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
            throw WhisperKitTranscriptionError.pipelineUnavailable
        }

        let fileURL = AVAudioRecorderService.recordingsDirectory.appendingPathComponent(audioFileID)
        print("[WhisperKit] transcribing \(audioFileID) with bounded disk chunks")

        let asset = AVURLAsset(url: fileURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw WhisperKitTranscriptionError.invalidAudio
        }

        let fileSize = Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let chunkCount = max(1, Int(ceil(duration / Self.diskChunkDuration)))
        var checkpoint = loadCheckpoint(recordingId: recordingId)
        if checkpoint?.matches(audioFileID: audioFileID, fileSize: fileSize, duration: duration) != true {
            checkpoint = PrivateTranscriptionCheckpoint(
                audioFileID: audioFileID,
                sourceFileSize: fileSize,
                sourceDuration: duration,
                nextChunkIndex: 0,
                speaker: Speaker(id: UUID(), name: "Speaker 1", isNameInferred: true, colorHex: "#6366F1"),
                segments: [],
                language: "en"
            )
            try saveCheckpoint(checkpoint!, recordingId: recordingId)
        }
        guard var checkpoint else { throw WhisperKitTranscriptionError.checkpointUnavailable }

        let resumeIndex = min(checkpoint.nextChunkIndex, chunkCount)
        if resumeIndex > 0 {
            print("[WhisperKit] resuming with \(resumeIndex)/\(chunkCount) chunks complete")
            statusUpdate?(OnDeviceTranscriptionProgress(
                fraction: Double(resumeIndex) / Double(chunkCount),
                currentChunk: min(resumeIndex + 1, chunkCount),
                totalChunks: chunkCount
            ))
        }

        for index in resumeIndex..<chunkCount {
            try Task.checkCancellation()
            let start = Double(index) * Self.diskChunkDuration
            let end = min(start + Self.diskChunkDuration, duration)
            let chunkURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("momentus-whisper-\(recordingId.uuidString)-\(index).m4a")
            try? FileManager.default.removeItem(at: chunkURL)

            do {
                try await exportChunk(from: asset, start: start, end: end, to: chunkURL)
                let progressGate = WhisperProgressGate()
                let notifier = statusUpdate.map(WhisperProgressNotifier.init(callback:))
                let callback: TranscriptionCallback? = notifier.map { notifier in
                    { @Sendable transcriptionProgress in
                        guard progressGate.shouldReport(windowID: transcriptionProgress.windowId) else {
                            return !Task.isCancelled
                        }
                        let processed = min(end - start, Double(transcriptionProgress.windowId + 1) * 30)
                        let fraction = (Double(index) + processed / max(1, end - start)) / Double(chunkCount)
                        notifier.send(OnDeviceTranscriptionProgress(
                            fraction: min(0.99, fraction),
                            currentChunk: index + 1,
                            totalChunks: chunkCount
                        ))
                        return !Task.isCancelled
                    }
                }
                let results = try await pipeline.transcribe(audioPath: chunkURL.path, callback: callback)
                checkpoint.segments.append(contentsOf: transcriptSegments(
                    from: results,
                    timeOffset: start,
                    speakerID: checkpoint.speaker.id
                ))
                if let language = results.first?.language { checkpoint.language = language }
                checkpoint.nextChunkIndex = index + 1
                try saveCheckpoint(checkpoint, recordingId: recordingId)
                statusUpdate?(OnDeviceTranscriptionProgress(
                    fraction: Double(index + 1) / Double(chunkCount),
                    currentChunk: index + 1,
                    totalChunks: chunkCount
                ))
                print("[WhisperKit] checkpointed chunk \(index + 1)/\(chunkCount)")
            } catch {
                try? FileManager.default.removeItem(at: chunkURL)
                throw error
            }
            try? FileManager.default.removeItem(at: chunkURL)
        }

        try? FileManager.default.removeItem(at: checkpointURL(recordingId: recordingId))
        try? FileManager.default.removeItem(at: Self.liveDraftURL(recordingId: recordingId))
        statusUpdate?(OnDeviceTranscriptionProgress(fraction: 1))
        print("[WhisperKit] done — \(checkpoint.segments.count) segments")
        return Transcript(
            id: UUID(),
            recordingId: recordingId,
            segments: checkpoint.segments,
            speakers: checkpoint.segments.isEmpty ? [] : [checkpoint.speaker],
            language: checkpoint.language,
            provider: providerName,
            createdAt: Date()
        )
    }

    // MARK: - Warmup

    /// Starts downloading/loading the model in the background. Call this when
    /// recording begins so the model is ready by the time recording stops.
    static func warmup() {
        guard pipeline == nil, !isLoading else { return }
        Task { await ensureLoaded() }
    }

    static func transcribeLiveAudio(_ samples: [Float]) async throws -> [TranscriptionResult] {
        await ensureLoaded()
        guard let pipeline else { throw WhisperKitTranscriptionError.pipelineUnavailable }
        return try await pipeline.transcribe(audioArray: samples)
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

    // MARK: - Disk chunks and checkpoints

    private func exportChunk(from asset: AVURLAsset, start: TimeInterval, end: TimeInterval, to url: URL) async throws {
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw WhisperKitTranscriptionError.chunkExportFailed
        }
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 1_000),
            end: CMTime(seconds: end, preferredTimescale: 1_000)
        )
        try await exporter.export(to: url, as: .m4a)
    }

    private func transcriptSegments(
        from results: [TranscriptionResult],
        timeOffset: TimeInterval,
        speakerID: UUID
    ) -> [TranscriptSegment] {
        results.flatMap(\.segments).compactMap { seg in
            guard let text = TranscriptTextSanitizer.cleaned(seg.text) else { return nil }
            let confidence = Float(max(0.0, min(1.0, exp(Double(seg.avgLogprob)))))
            return TranscriptSegment(
                id: UUID(),
                text: text,
                startTime: timeOffset + Double(seg.start),
                endTime: timeOffset + Double(seg.end),
                speakerId: speakerID,
                confidence: confidence
            )
        }
    }

    private func checkpointURL(recordingId: UUID) -> URL {
        AVAudioRecorderService.recordingsDirectory
            .appendingPathComponent("private-transcription-\(recordingId.uuidString).json")
    }

    static func liveDraftURL(recordingId: UUID) -> URL {
        AVAudioRecorderService.recordingsDirectory
            .appendingPathComponent("private-live-\(recordingId.uuidString).json")
    }

    private func loadCheckpoint(recordingId: UUID) -> PrivateTranscriptionCheckpoint? {
        guard let data = try? Data(contentsOf: checkpointURL(recordingId: recordingId)) else { return nil }
        return try? JSONDecoder().decode(PrivateTranscriptionCheckpoint.self, from: data)
    }

    private func saveCheckpoint(_ checkpoint: PrivateTranscriptionCheckpoint, recordingId: UUID) throws {
        let data = try JSONEncoder().encode(checkpoint)
        try data.write(to: checkpointURL(recordingId: recordingId), options: .atomic)
    }
}

private struct PrivateTranscriptionCheckpoint: Codable {
    var version = 1
    let audioFileID: String
    let sourceFileSize: Int64
    let sourceDuration: TimeInterval
    var nextChunkIndex: Int
    let speaker: Speaker
    var segments: [TranscriptSegment]
    var language: String

    func matches(audioFileID: String, fileSize: Int64, duration: TimeInterval) -> Bool {
        version == 1
            && self.audioFileID == audioFileID
            && sourceFileSize == fileSize
            && abs(sourceDuration - duration) < 0.5
    }
}

enum WhisperKitTranscriptionError: LocalizedError {
    case invalidAudio
    case chunkExportFailed
    case checkpointUnavailable
    case pipelineUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidAudio: return "The saved recording could not be read for private transcription."
        case .chunkExportFailed: return "Momentus could not prepare the next private transcription chunk."
        case .checkpointUnavailable: return "Momentus could not create a private transcription checkpoint."
        case .pipelineUnavailable: return "The private transcription model could not be loaded."
        }
    }
}

/// Bounded, provisional transcription while the authoritative audio file is recorded.
/// The final disk pass remains responsible for the durable transcript.
final class LiveWhisperTranscriptionSession {
    private static let sampleRate = 16_000.0
    private static let decodeSeconds = 30.0
    private static let maximumBacklogSeconds = 3 * 60.0

    private let recordingID: UUID
    private let update: @MainActor (String, String) -> Void
    private var pendingSamples: [Float] = []
    private var confirmedText: [String] = []
    private var processingTask: Task<Void, Never>?
    private var isStopped = false

    init(recordingID: UUID, update: @escaping @MainActor (String, String) -> Void) {
        self.recordingID = recordingID
        self.update = update
        update("Listening for speech", "")
    }

    func append(samples: [Float], sourceSampleRate: Double) {
        guard !isStopped, !samples.isEmpty, sourceSampleRate > 0 else { return }
        pendingSamples.append(contentsOf: Self.resample(samples, from: sourceSampleRate, to: Self.sampleRate))

        let maximumSamples = Int(Self.maximumBacklogSeconds * Self.sampleRate)
        if pendingSamples.count > maximumSamples {
            pendingSamples.removeFirst(pendingSamples.count - maximumSamples)
            update("Live preview catching up — audio is safe on disk", confirmedText.joined(separator: " "))
        }
        scheduleDecodeIfNeeded()
    }

    func stop() async {
        isStopped = true
        processingTask?.cancel()
        await processingTask?.value
        processingTask = nil
    }

    private func scheduleDecodeIfNeeded() {
        guard processingTask == nil else { return }
        let required = Int(Self.decodeSeconds * Self.sampleRate)
        guard pendingSamples.count >= required else { return }

        let thermalState = ProcessInfo.processInfo.thermalState
        guard thermalState != .serious, thermalState != .critical else {
            update("Live preview paused to keep your phone cool", confirmedText.joined(separator: " "))
            return
        }

        let audio = Array(pendingSamples.prefix(required))
        pendingSamples.removeFirst(required)
        update("Updating private transcript", confirmedText.joined(separator: " "))
        processingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let results = try await WhisperKitTranscriptionService.transcribeLiveAudio(audio)
                try Task.checkCancellation()
                let text = results
                    .flatMap(\.segments)
                    .compactMap { TranscriptTextSanitizer.cleaned($0.text) }
                    .joined(separator: " ")
                if !text.isEmpty { confirmedText.append(text) }
                persistDraft()
                update("Private transcript active", confirmedText.joined(separator: " "))
            } catch is CancellationError {
                // The bounded disk pass takes over as soon as recording stops.
            } catch {
                print("[WhisperKit Live] preview chunk failed: \(error)")
                update("Live preview paused — audio is safe on disk", confirmedText.joined(separator: " "))
            }
            processingTask = nil
            if !isStopped { scheduleDecodeIfNeeded() }
        }
    }

    private func persistDraft() {
        let draft = LivePrivateTranscriptDraft(text: confirmedText.joined(separator: " "), updatedAt: Date())
        guard let data = try? JSONEncoder().encode(draft) else { return }
        try? data.write(
            to: WhisperKitTranscriptionService.liveDraftURL(recordingId: recordingID),
            options: .atomic
        )
    }

    private static func resample(_ input: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        guard abs(sourceRate - targetRate) > 1 else { return input }
        let outputCount = max(1, Int(Double(input.count) * targetRate / sourceRate))
        return (0..<outputCount).map { index in
            let sourcePosition = Double(index) * sourceRate / targetRate
            let lower = min(input.count - 1, Int(sourcePosition))
            let upper = min(input.count - 1, lower + 1)
            let fraction = Float(sourcePosition - Double(lower))
            return input[lower] + (input[upper] - input[lower]) * fraction
        }
    }
}

private struct LivePrivateTranscriptDraft: Codable {
    let text: String
    let updatedAt: Date
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
