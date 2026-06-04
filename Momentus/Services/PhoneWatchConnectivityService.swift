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
    private var fileHandler: ((String, [TimeInterval], String?) -> Void)?

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

    func clearPendingRecordings() {
        UserDefaults.standard.removeObject(forKey: pendingKey)
    }

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func configure(
        actionHandler: @escaping (String, TimeInterval?, String?) -> Void,
        fileHandler: @escaping (String, [TimeInterval], String?) -> Void
    ) {
        self.actionHandler = actionHandler
        self.fileHandler = fileHandler
    }

    // MARK: - Notify Watch that processing finished

    func notifyWatchRecordingComplete() {
        guard WCSession.default.activationState == .activated,
              WCSession.default.isWatchAppInstalled else { return }
        let message = ["action": "recordingProcessed"]
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

    // MARK: - Receiving messages

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handle(message)
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
            try FileManager.default.copyItem(at: file.fileURL, to: destURL)
        } catch {
            print("[WatchConnectivity] failed to copy audio file: \(error)")
            return
        }

        let audioFileID = destURL.lastPathComponent

        if let handler = fileHandler {
            Task { @MainActor in handler(audioFileID, markers, mode) }
        } else {
            // RecordViewModel hasn't initialised yet — queue for when it does.
            var pending = pendingRecordings
            pending.append(PendingWatchRecording(audioFileID: audioFileID, markers: markers, mode: mode))
            pendingRecordings = pending
            print("[WatchConnectivity] queued \(audioFileID) — RecordViewModel not ready yet")
        }
    }

    // MARK: - Internal

    private func handle(_ message: [String: Any]) {
        guard let action = message["action"] as? String else { return }
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
    ) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }
}
