import AVFoundation
import Foundation

final class AVAudioRecorderService: RecordingService {

    private(set) var isRecording = false

    private var recorder: AVAudioRecorder?
    private var currentFileURL: URL?

    static let recordingsDirectory: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func startRecording(mode: RecordingMode, source: MicSource) async throws -> UUID {
        print("[Audio] startRecording — mic permission: \(AVAudioApplication.shared.recordPermission.rawValue)")

        let session = AVAudioSession.sharedInstance()
        // .playAndRecord is more reliable than .record on many devices:
        // it keeps the audio engine active and avoids session-transition stalls.
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)
        print("[Audio] session active — category: \(session.category.rawValue), sampleRate: \(session.sampleRate)")

        let recordingId = UUID()
        let fileURL = Self.recordingsDirectory.appendingPathComponent("\(recordingId.uuidString).m4a")
        currentFileURL = fileURL

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let rec = try AVAudioRecorder(url: fileURL, settings: settings)
        rec.isMeteringEnabled = true
        let started = rec.record()
        print("[Audio] recorder.record() returned \(started), isRecording: \(rec.isRecording)")

        guard started else {
            throw AVAudioRecorderServiceError.recordingFailed
        }

        recorder = rec
        isRecording = true
        return recordingId
    }

    func stopRecording() async throws -> String {
        print("[Audio] stopRecording — recorder.isRecording: \(recorder?.isRecording ?? false)")
        recorder?.stop()
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        guard let url = currentFileURL else {
            throw AVAudioRecorderServiceError.noActiveRecording
        }

        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        print("[Audio] file: \(url.lastPathComponent) — \(fileSize) bytes")

        return url.lastPathComponent
    }

    func pauseRecording() async throws {
        recorder?.pause()
    }

    func resumeRecording() async throws {
        recorder?.record()
    }

    func getCurrentLevel() -> Float {
        guard let recorder, isRecording else { return 0.05 }
        recorder.updateMeters()
        let db = recorder.averagePower(forChannel: 0)
        let normalized = (db + 80.0) / 80.0
        return max(0.05, min(1.0, normalized))
    }
}

enum AVAudioRecorderServiceError: LocalizedError {
    case noActiveRecording
    case recordingFailed

    var errorDescription: String? {
        switch self {
        case .noActiveRecording: return "No active recording to stop."
        case .recordingFailed: return "Failed to start the audio recorder. Check microphone permission."
        }
    }
}
