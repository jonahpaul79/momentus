import SwiftUI
import WatchConnectivity

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
    var micTarget: MicTarget = .iPhone
    var selectedMode: WatchRecordingMode = .onDevice
    var waveformLevels: [Float] = Array(repeating: 0.1, count: 16)
    var isConnectedToPhone = false

    enum MicTarget { case iPhone, watch }
    enum WatchRecordingMode: String, CaseIterable {
        case onDevice = "Private"
        case bestQuality = "Quality"
    }

    private var timerTask: Task<Void, Never>?
    private var waveformTask: Task<Void, Never>?

    override init() {
        super.init()
        setupWatchConnectivity()
    }

    // MARK: - Actions

    func startRecording() async {
        guard recordingState == .idle else { return }
        recordingState = .recording
        elapsedTime = 0
        startTimers()
        sendToPhone(["action": "startRecording", "mode": selectedMode.rawValue])
    }

    func stopRecording() async {
        guard recordingState == .recording || recordingState == .paused else { return }
        stopTimers()
        sendToPhone(["action": "stopRecording"])
        recordingState = .processing
        // Simulate phone processing acknowledgment
        try? await Task.sleep(for: .seconds(1))
        recordingState = .saved
    }

    func pauseRecording() async {
        guard recordingState == .recording else { return }
        recordingState = .paused
        stopWaveformTimer()
        sendToPhone(["action": "pauseRecording"])
    }

    func addMarker() {
        sendToPhone(["action": "addMarker", "timestamp": elapsedTime])
    }

    func recordAnother() {
        recordingState = .idle
        elapsedTime = 0
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
        waveformTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { break }
                var levels = self.waveformLevels
                levels.removeFirst()
                levels.append(Float.random(in: 0.1...0.9))
                self.waveformLevels = levels
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

    // MARK: - Watch Connectivity

    private func setupWatchConnectivity() {
        // TODO: Implement WCSession activation for iOS ↔ watchOS communication
        // guard WCSession.isSupported() else { return }
        // WCSession.default.delegate = self
        // WCSession.default.activate()
    }

    private func sendToPhone(_ message: [String: Any]) {
        // TODO: WCSession.default.sendMessage(message, replyHandler: nil)
        _ = message
    }
}
