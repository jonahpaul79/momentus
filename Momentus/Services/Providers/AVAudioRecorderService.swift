@preconcurrency import AVFoundation
import Foundation

/// Single-source audio capture. One input tap writes the authoritative AAC file
/// and optionally fans copied PCM samples out to the live private transcript.
final class AVAudioRecorderService: LiveAudioSampleSource {
    var isRecording: Bool { engine?.isRunning == true && captureState?.writeError == nil }
    var recordedDuration: TimeInterval { captureState?.duration ?? lastRecordedDuration }

    private var engine: AVAudioEngine?
    private var captureState: AudioCaptureState?
    private var currentFileURL: URL?
    private var lastRecordedDuration: TimeInterval = 0

    static let recordingsDirectory: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func startRecording(mode: RecordingMode, source: MicSource) async throws -> UUID {
        print("[Audio] startRecording — mic permission: \(AVAudioApplication.shared.recordPermission.rawValue)")
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)

        let recordingId = UUID()
        let fileURL = Self.recordingsDirectory.appendingPathComponent("\(recordingId.uuidString).m4a")
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AVAudioRecorderServiceError.recordingFailed
        }
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let audioFile = try AVAudioFile(forWriting: fileURL, settings: settings)

        let state = AudioCaptureState(file: audioFile, sampleRate: format.sampleRate)
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { buffer, _ in
            state.consume(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }

        self.engine = engine
        captureState = state
        currentFileURL = fileURL
        lastRecordedDuration = 0
        print("[Audio] capture engine active — \(format.sampleRate) Hz, \(format.channelCount) channel(s)")
        return recordingId
    }

    func stopRecording() async throws -> String {
        print("[Audio] stopRecording — engine.isRunning: \(engine?.isRunning ?? false)")
        stopLiveSampleDelivery()
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        let writeError: Error?
        if let captureState {
            lastRecordedDuration = captureState.duration
            captureState.close()
            writeError = captureState.writeError
        } else {
            writeError = nil
        }
        self.engine = nil
        self.captureState = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        guard let url = currentFileURL else { throw AVAudioRecorderServiceError.noActiveRecording }
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        print("[Audio] file: \(url.lastPathComponent) — \(fileSize) bytes")
        if let writeError {
            print("[Audio] capture ended after a write error; preserving playable audio: \(writeError)")
            if fileSize == 0 { throw writeError }
        }
        return url.lastPathComponent
    }

    func pauseRecording() async throws {
        guard engine?.isRunning == true else { return }
        lastRecordedDuration = captureState?.duration ?? lastRecordedDuration
        engine?.pause()
    }

    func resumeRecording() async throws {
        guard let engine else { throw AVAudioRecorderServiceError.noActiveRecording }
        try AVAudioSession.sharedInstance().setActive(true)
        try engine.start()
    }

    func getCurrentLevel() -> Float { captureState?.level ?? 0.03 }

    func startLiveSampleDelivery(
        _ handler: @escaping @Sendable ([Float], Double) -> Void
    ) throws {
        guard let captureState else { throw AVAudioRecorderServiceError.liveSamplesUnavailable }
        captureState.setLiveHandler(handler)
        print("[Audio] live sample fan-out enabled")
    }

    func stopLiveSampleDelivery() {
        captureState?.setLiveHandler(nil)
    }
}

private final class AudioCaptureState: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var file: AVAudioFile?
    private let sampleRate: Double
    nonisolated(unsafe) private var writtenFrames: AVAudioFramePosition = 0
    nonisolated(unsafe) private var currentLevel: Float = 0.03
    nonisolated(unsafe) private var handler: (@Sendable ([Float], Double) -> Void)?
    nonisolated(unsafe) private var capturedWriteError: Error?

    init(file: AVAudioFile, sampleRate: Double) {
        self.file = file
        self.sampleRate = sampleRate
    }

    var duration: TimeInterval { lock.withLock { Double(writtenFrames) / sampleRate } }
    var level: Float { lock.withLock { currentLevel } }
    var writeError: Error? { lock.withLock { capturedWriteError } }

    nonisolated func consume(_ buffer: AVAudioPCMBuffer) {
        let liveHandler: (@Sendable ([Float], Double) -> Void)?
        var mono: [Float] = []

        lock.lock()
        if capturedWriteError == nil {
            do {
                try file?.write(from: buffer)
                writtenFrames += AVAudioFramePosition(buffer.frameLength)
            } catch {
                capturedWriteError = error
            }
        }
        liveHandler = handler

        if let channels = buffer.floatChannelData {
            let frameCount = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)
            var sumSquares: Float = 0
            if liveHandler != nil { mono = [Float](repeating: 0, count: frameCount) }
            for channel in 0..<channelCount {
                let source = channels[channel]
                for frame in 0..<frameCount {
                    let sample = source[frame]
                    sumSquares += sample * sample / Float(channelCount)
                    if liveHandler != nil { mono[frame] += sample / Float(channelCount) }
                }
            }
            if frameCount > 0 {
                let rms = sqrt(sumSquares / Float(frameCount))
                currentLevel = min(1, max(0.02, pow(rms * 8, 0.7)))
            }
        }
        lock.unlock()

        if !mono.isEmpty { liveHandler?(mono, buffer.format.sampleRate) }
    }

    func setLiveHandler(_ handler: (@Sendable ([Float], Double) -> Void)?) {
        lock.withLock { self.handler = handler }
    }

    func close() {
        lock.withLock { file = nil }
    }
}

enum AVAudioRecorderServiceError: LocalizedError {
    case noActiveRecording
    case recordingFailed
    case liveSamplesUnavailable

    var errorDescription: String? {
        switch self {
        case .noActiveRecording: return "No active recording to stop."
        case .recordingFailed: return "Failed to start the audio recorder. Check microphone permission."
        case .liveSamplesUnavailable: return "Live private transcription is unavailable for this microphone. The recording will continue normally."
        }
    }
}
