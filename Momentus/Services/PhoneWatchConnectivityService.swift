import Foundation
import WatchConnectivity

final class PhoneWatchConnectivityService: NSObject, WCSessionDelegate {
    static let shared = PhoneWatchConnectivityService()

    private var actionHandler: ((String, TimeInterval?, String?) -> Void)?
    private var fileHandler: ((String, [TimeInterval], String?) -> Void)?

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
        Task { @MainActor in
            self.fileHandler?(audioFileID, markers, mode)
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
