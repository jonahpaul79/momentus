import SwiftUI
import WatchConnectivity
import WatchKit
import AVFoundation

enum WatchRecordingState: Equatable {
    case idle
    case recording
    case paused
    case processing
    case saved
}

@Observable final class WatchViewModel: NSObject {
    var recordingState: WatchRecordingState = .idle
    var elapsedTime: TimeInterval = 0
    var selectedMode: WatchRecordingMode = .onDevice
    var waveformLevels: [Float] = Array(repeating: 0.1, count: 20)
    var markerHighlightedBars: Set<Int> = []
    var isConnectedToPhone = false
    var markers: [TimeInterval] = []

    enum WatchRecordingMode: String, CaseIterable {
        case onDevice = "Private"
        case bestQuality = "Quality"
    }

    private var timerTask: Task<Void, Never>?
    private var waveformTask: Task<Void, Never>?
    private var extendedRuntimeSession: WKExtendedRuntimeSession?
    private var audioRecorder: AVAudioRecorder?
    private var watchRecordingURL: URL?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // MARK: - Actions

    func startRecording() async {
        guard recordingState == .idle else { return }
        recordingState = .recording
        elapsedTime = 0
        markers = []
        markerHighlightedBars = []

        let session = WKExtendedRuntimeSession()
        session.start()
        extendedRuntimeSession = session

        startAudioCapture()
        startTimers()
    }

    func stopRecording() async {
        guard recordingState == .recording || recordingState == .paused else { return }
        stopTimers()
        extendedRuntimeSession?.invalidate()
        extendedRuntimeSession = nil
        recordingState = .processing

        if let url = stopAudioCapture() {
            let markerStr = markers.map { String(format: "%.2f", $0) }.joined(separator: ",")
            WCSession.default.transferFile(url, metadata: [
                "action": "processWatchRecording",
                "mode": selectedMode.rawValue,
                "markers": markerStr,
                "duration": String(format: "%.1f", elapsedTime)
            ])
        }

        try? await Task.sleep(for: .seconds(2))
        recordingState = .saved
    }

    func pauseRecording() async {
        guard recordingState == .recording else { return }
        recordingState = .paused
        audioRecorder?.pause()
        stopWaveformTimer()
    }

    func resumeRecording() async {
        guard recordingState == .paused else { return }
        recordingState = .recording
        audioRecorder?.record()
        startWaveformTimer()
    }

    func addMarker() {
        guard recordingState == .recording || recordingState == .paused else { return }
        markers.append(elapsedTime)
        markerHighlightedBars.insert(waveformLevels.count - 1)
    }

    func recordAnother() {
        recordingState = .idle
        elapsedTime = 0
        markerHighlightedBars = []
        markers = []
    }

    // MARK: - Audio

    private func startAudioCapture() {
        let avSession = AVAudioSession.sharedInstance()
        do {
            try avSession.setCategory(.record, mode: .default)
            try avSession.setActive(true)
        } catch {
            print("[Watch Audio] session setup failed: \(error)")
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                print("[Watch Audio] recorder.record() returned false — mic permission may not be granted")
                return
            }
            audioRecorder = recorder
            watchRecordingURL = url
            print("[Watch Audio] recording started: \(url.lastPathComponent)")
        } catch {
            print("[Watch Audio] recorder init failed: \(error)")
        }
    }

    private func stopAudioCapture() -> URL? {
        audioRecorder?.stop()
        audioRecorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let url = watchRecordingURL
        watchRecordingURL = nil
        return url
    }

    // MARK: - Timers

    private func startTimers() {
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { break }
                self?.elapsedTime += 0.1
            }
        }
        startWaveformTimer()
    }

    private func startWaveformTimer() {
        stopWaveformTimer()
        waveformTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self else { break }
                var levels = self.waveformLevels
                levels.removeFirst()

                let level: Float
                if let recorder = self.audioRecorder, recorder.isRecording {
                    recorder.updateMeters()
                    let db = recorder.averagePower(forChannel: 0)
                    let normalized = max(0, min(1, (db + 55) / 50))
                    level = pow(normalized, 1.7)
                } else {
                    level = Float.random(in: 0.08...0.95)
                }
                levels.append(level)
                self.waveformLevels = levels
                self.markerHighlightedBars = Set(self.markerHighlightedBars.compactMap { idx in
                    let shifted = idx - 1
                    return shifted >= 0 ? shifted : nil
                })
            }
        }
    }

    private func stopWaveformTimer() {
        waveformTask?.cancel()
        waveformTask = nil
    }

    private func stopTimers() {
        timerTask?.cancel()
        waveformTask?.cancel()
        timerTask = nil
        waveformTask = nil
    }
}

// MARK: - WCSessionDelegate

extension WatchViewModel: WCSessionDelegate {
    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        isConnectedToPhone = activationState == .activated
    }
}
