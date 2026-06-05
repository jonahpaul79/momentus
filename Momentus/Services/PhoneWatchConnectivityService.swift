import Foundation
import WatchConnectivity

struct PendingWatchRecording: Codable {
    let audioFileID: String
    let markers: [TimeInterval]
    let mode: String?
}

final class PhoneWatchConnectivityService: NSObject, WCSessionDelegate {
    static let shared = PhoneWatchConnectivityService()

    private var actionHandler: ((String, TimeInterval?, String?) -> Void)?

    private let pendingKey = "momentus_pending_watch_recordings"

    var pendingRecordings: [PendingWatchRecording] {
        get {
            guard let data = UserDefaults.standard.data(forKey: pendingKey),
                  let items = try? JSONDecoder().decode([PendingWatchRecording].self, from: data)
            else { return [] }
            return items
        }
        set {
            UserDefaults.standard.set(
                try? JSONEncoder().encode(newValue),
                forKey: pendingKey
            )
        }
    }

    func addPendingRecording(_ recording: PendingWatchRecording) {
        var items = pendingRecordings
        guard !items.contains(where: { $0.audioFileID == recording.audioFileID }) else { return }
        items.append(recording)
        pendingRecordings = items
    }

    func removePendingRecording(audioFileID: String) {
        pendingRecordings = pendingRecordings.filter { $0.audioFileID != audioFileID }
    }

    func clearPendingRecordings() {
        UserDefaults.standard.removeObject(forKey: pendingKey)
    }

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func configure(actionHandler: @escaping (String, TimeInterval?, String?) -> Void) {
        self.actionHandler = actionHandler
    }

    // MARK: - Notify Watch that processing finished

    func notifyWatchRecordingComplete() {
        guard WCSession.default.activationState == .activated,
              WCSession.default.isWatchAppInstalled else { return }
        let message = ["action": "recordingProcessed"]
        sendWatchStatusMessage(message)
    }

    func notifyWatchRecordingFailed() {
        guard WCSession.default.activationState == .activated,
              WCSession.default.isWatchAppInstalled else { return }
        let message = ["action": "recordingFailed"]
        sendWatchStatusMessage(message)
    }

    func sendWatchCloudConfiguration() {
        guard WCSession.default.activationState == .activated,
              WCSession.default.isWatchAppInstalled else { return }

        var message: [String: String] = [
            "action": "watchCloudConfig",
            "defaultMode": UserDefaults.standard.string(forKey: "defaultRecordingMode") ?? RecordingMode.onDevice.rawValue
        ]
        if let assemblyAIKey = KeychainService.retrieve(.assemblyAIAPIKey), !assemblyAIKey.isEmpty {
            message["assemblyAIAPIKey"] = assemblyAIKey
        }
        if let anthropicKey = KeychainService.retrieve(.anthropicAPIKey), !anthropicKey.isEmpty {
            message["anthropicAPIKey"] = anthropicKey
        }
        sendWatchStatusMessage(message)
    }

    func notifyWatchRecordingReceived() {
        sendWatchRecordingStatus("watchRecordingReceived")
    }

    func notifyWatchRecordingProcessing() {
        sendWatchRecordingStatus("watchRecordingProcessing")
    }

    func notifyWatchRecordingNeedsPhoneWake() {
        sendWatchRecordingStatus("watchRecordingNeedsPhoneWake")
    }

    private func sendWatchRecordingStatus(_ action: String) {
        guard WCSession.default.activationState == .activated,
              WCSession.default.isWatchAppInstalled else { return }
        sendWatchStatusMessage(["action": action])
    }

    private func sendWatchStatusMessage(_ message: [String: String]) {
        try? WCSession.default.updateApplicationContext(message)

        if WCSession.default.isReachable {
            WCSession.default.sendMessage(message, replyHandler: nil) { _ in
                // Watch wasn't reachable in real-time — queue via transferUserInfo so it
                // arrives when the Watch next wakes.
                WCSession.default.transferUserInfo(message)
            }
        } else {
            WCSession.default.transferUserInfo(message)
        }
    }

    func sendWatchRecordingAction(
        _ action: String,
        timestamp: TimeInterval? = nil,
        mode: RecordingMode? = nil
    ) async throws {
        guard WCSession.default.activationState == .activated else {
            throw PhoneWatchConnectivityError.watchSessionInactive
        }
        guard WCSession.default.isWatchAppInstalled else {
            throw PhoneWatchConnectivityError.watchAppNotInstalled
        }
        guard WCSession.default.isReachable else {
            throw PhoneWatchConnectivityError.watchNotReachable
        }

        var message: [String: Any] = ["action": action]
        if let timestamp {
            message["timestamp"] = timestamp
        }
        if let mode {
            message["mode"] = mode == .bestQuality ? "Quality" : "Private"
        }

        try await withCheckedThrowingContinuation { continuation in
            WCSession.default.sendMessage(message, replyHandler: { _ in
                continuation.resume()
            }, errorHandler: { error in
                continuation.resume(throwing: error)
            })
        }
    }

    // MARK: - Receiving messages

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handle(message)
    }

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        if (message["action"] as? String) == "watchRecordingPhoneProbe" {
            replyHandler(["available": true])
            return
        }
        handle(message)
        replyHandler(["ok": true])
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        handle(userInfo)
    }

    // MARK: - Receiving audio file from watch

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard (file.metadata?["action"] as? String) == "processWatchRecording" else { return }

        let mode = file.metadata?["mode"] as? String
        let markersStr = (file.metadata?["markers"] as? String) ?? ""
        let markers: [TimeInterval] = markersStr.isEmpty ? [] :
            markersStr.split(separator: ",").compactMap { Double($0) }

        // Copy to a stable location — WCSessionFile URL is only valid during this callback
        let destURL = AVAudioRecorderService.recordingsDirectory
            .appendingPathComponent(file.fileURL.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: file.fileURL, to: destURL)
        } catch {
            print("[WatchConnectivity] failed to copy audio file: \(error)")
            notifyWatchRecordingFailed()
            return
        }

        let audioFileID = destURL.lastPathComponent
        addPendingRecording(PendingWatchRecording(audioFileID: audioFileID, markers: markers, mode: mode))
        MomentusAppDelegate.scheduleWatchRecordingProcessingTask()
        notifyWatchRecordingReceived()

        Task { @MainActor in
            WatchRecordingProcessor.shared.enqueue(audioFileID: audioFileID, markers: markers, mode: mode)
        }
    }

    // MARK: - Internal

    private func handle(_ message: [String: Any]) {
        guard let action = message["action"] as? String else { return }
        if action == "watchRecordingTransferStarted" {
            print("[WatchConnectivity] watch recording transfer starting")
            MomentusAppDelegate.scheduleWatchRecordingProcessingTask()
            WhisperKitTranscriptionService.warmup()
            return
        }
        if action == "watchCloudRecordingProcessed" {
            Task { @MainActor in
                WatchRecordingProcessor.shared.importCloudProcessedRecording(message)
            }
            return
        }

        let timestamp = message["timestamp"] as? TimeInterval
        let mode = message["mode"] as? String
        Task { @MainActor in
            actionHandler?(action, timestamp, mode)
        }
    }

    // MARK: - WCSessionDelegate lifecycle

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if activationState == .activated {
            sendWatchCloudConfiguration()
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }
}

enum PhoneWatchConnectivityError: LocalizedError {
    case watchSessionInactive
    case watchAppNotInstalled
    case watchNotReachable

    var errorDescription: String? {
        switch self {
        case .watchSessionInactive:
            return "Apple Watch connection is not ready yet."
        case .watchAppNotInstalled:
            return "Momentus is not installed on your Apple Watch."
        case .watchNotReachable:
            return "Apple Watch is not reachable. Open Momentus on the Watch and try again."
        }
    }
}
