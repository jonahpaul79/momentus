import Foundation

enum CloudAIConsent {
    nonisolated static let preferenceKey = "cloudAIConsentVersion"
    nonisolated static let currentVersion = "2026-08-26-v1"

    nonisolated static var isGranted: Bool {
        UserDefaults.standard.string(forKey: preferenceKey) == currentVersion
    }

    @MainActor
    static func grant() {
        UserDefaults.standard.set(currentVersion, forKey: preferenceKey)
        PhoneWatchConnectivityService.shared.sendWatchCloudConfiguration()
    }

    @MainActor
    static func revoke() {
        UserDefaults.standard.removeObject(forKey: preferenceKey)
        PhoneWatchConnectivityService.shared.sendWatchCloudConfiguration()
    }

    nonisolated static func requiresConsent(for operation: String) -> Bool {
        switch operation {
        case "assemblyai.upload", "assemblyai.create", "assemblyai.lemur", "anthropic.messages":
            return true
        default:
            return false
        }
    }
}

enum CloudAIConsentError: LocalizedError {
    case required

    var errorDescription: String? {
        "Cloud AI permission is required before meeting data can be sent to third-party AI services."
    }
}
