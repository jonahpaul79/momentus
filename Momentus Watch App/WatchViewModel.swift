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

enum WatchProcessingStatus: Equatable {
    case sending
    case received
    case processingOnPhone
    case needsPhoneWake
    case failed
}

@Observable final class WatchViewModel: NSObject {
    var recordingState: WatchRecordingState = .idle
    var elapsedTime: TimeInterval = 0
    var selectedMode: WatchRecordingMode = .onDevice
    var waveformLevels: [Float] = Array(repeating: 0.1, count: 20)
    var markerHighlightedBars: Set<Int> = []
    var isConnectedToPhone = false
    var markers: [TimeInterval] = []
    var processingElapsed: TimeInterval = 0
    var processingStatus: WatchProcessingStatus = .sending

    enum WatchRecordingMode: String, CaseIterable {
        case onDevice = "Private"
        case bestQuality = "Quality"
    }

    private var timerTask: Task<Void, Never>?
    private var waveformTask: Task<Void, Never>?
    private var processingTimerTask: Task<Void, Never>?
    private var extendedRuntimeSession: WKExtendedRuntimeSession?
    private var audioRecorder: AVAudioRecorder?
    private var watchRecordingURL: URL?
    private var activeTransferFileNames: Set<String> = []

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
        processingStatus = .sending
        startProcessingTimer()

        if let url = stopAudioCapture(), let transferURL = prepareTransferFile(from: url) {
            let markerStr = markers.map { String(format: "%.2f", $0) }.joined(separator: ",")
            activeTransferFileNames.insert(transferURL.lastPathComponent)
            WCSession.default.transferFile(transferURL, metadata: [
                "action": "processWatchRecording",
                "mode": selectedMode.rawValue,
                "markers": markerStr,
                "duration": String(format: "%.1f", elapsedTime)
            ])
        } else {
            processingStatus = .failed
        }

        // Stay in .processing until the phone confirms via WCSession.
        // Fall back to .saved after 10 minutes in case phone is unreachable.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))
            guard let self, self.recordingState == .processing else { return }
            self.recordingState = .saved
        }
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
        processingElapsed = 0
        markerHighlightedBars = []
        markers = []
    }

    // MARK: - Processing timer

    private func startProcessingTimer() {
        processingElapsed = 0
        processingTimerTask?.cancel()
        processingTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let shouldContinue = await MainActor.run {
                    guard !Task.isCancelled, let self, self.recordingState == .processing else { return false }
                    self.processingElapsed += 1
                    self.updateProcessingTimeout()
                    return true
                }
                guard shouldContinue else { break }
            }
        }
    }

    private func updateProcessingTimeout() {
        switch processingStatus {
        case .sending where processingElapsed >= 35:
            processingStatus = .needsPhoneWake
        case .received where processingElapsed >= 120,
             .processingOnPhone where processingElapsed >= 120:
            processingStatus = .needsPhoneWake
        default:
            break
        }
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

    private func prepareTransferFile(from sourceURL: URL) -> URL? {
        let outboxURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WatchRecordingOutbox", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: outboxURL, withIntermediateDirectories: true)
            let destURL = outboxURL.appendingPathComponent(sourceURL.lastPathComponent)
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
            let fileSize = (try? destURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard fileSize > 1024 else {
                print("[WatchConnectivity] transfer file is empty: \(fileSize) bytes")
                return nil
            }
            return destURL
        } catch {
            print("[WatchConnectivity] failed to prepare transfer file: \(error)")
            return nil
        }
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
                    let normalized = max(0, min(1, (db + 58) / 46))
                    level = max(0.12, pow(normalized, 0.75))
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

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handlePhoneMessage(message)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        handlePhoneMessage(userInfo)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handlePhoneMessage(applicationContext)
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let fileName = fileTransfer.file.fileURL.lastPathComponent
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.activeTransferFileNames.remove(fileName)
            if let error {
                print("[WatchConnectivity] file transfer failed: \(error)")
                if self.recordingState == .processing {
                    self.processingStatus = .needsPhoneWake
                }
                return
            }

            try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
            if self.recordingState == .processing, self.processingStatus == .sending {
                self.processingStatus = .received
            }
        }
    }

    private func handlePhoneMessage(_ message: [String: Any]) {
        guard let action = message["action"] as? String else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch action {
            case "recordingProcessed":
                guard self.recordingState == .processing else { return }
                self.recordingState = .saved
            case "recordingFailed":
                guard self.recordingState == .processing else { return }
                self.processingStatus = .failed
            case "watchRecordingReceived":
                guard self.recordingState == .processing else { return }
                self.processingStatus = .received
            case "watchRecordingProcessing":
                guard self.recordingState == .processing else { return }
                self.processingStatus = .processingOnPhone
            case "watchRecordingNeedsPhoneWake":
                guard self.recordingState == .processing else { return }
                self.processingStatus = .needsPhoneWake
            case "startRecording":
                if let mode = message["mode"] as? String {
                    if mode == WatchRecordingMode.bestQuality.rawValue {
                        self.selectedMode = .bestQuality
                    } else if mode == WatchRecordingMode.onDevice.rawValue {
                        self.selectedMode = .onDevice
                    }
                }
                await self.startRecording()
            case "stopRecording":
                await self.stopRecording()
            case "pauseRecording":
                await self.pauseRecording()
            case "resumeRecording":
                await self.resumeRecording()
            case "addMarker":
                if let timestamp = message["timestamp"] as? TimeInterval {
                    self.markers.append(timestamp)
                    self.markerHighlightedBars.insert(self.waveformLevels.count - 1)
                } else {
                    self.addMarker()
                }
            default:
                break
            }
        }
    }
}
