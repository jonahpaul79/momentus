import Foundation
import WatchConnectivity

final class PhoneWatchConnectivityService: NSObject, WCSessionDelegate {
    static let shared = PhoneWatchConnectivityService()

    private var actionHandler: ((String, TimeInterval?, String?) -> Void)?

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func configure(actionHandler: @escaping (String, TimeInterval?, String?) -> Void) {
        self.actionHandler = actionHandler
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handle(message)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        handle(userInfo)
    }

    private func handle(_ message: [String: Any]) {
        guard let action = message["action"] as? String else { return }
        let timestamp = message["timestamp"] as? TimeInterval
        let mode = message["mode"] as? String
        Task { @MainActor in
            actionHandler?(action, timestamp, mode)
        }
    }

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
