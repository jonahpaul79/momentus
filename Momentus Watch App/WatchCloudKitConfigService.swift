import CloudKit
import Foundation

struct WatchCloudProviderConfig {
    let defaultMode: String
    let assemblyAIAPIKey: String
    let anthropicAPIKey: String
}

final class WatchCloudKitConfigService {
    static let shared = WatchCloudKitConfigService()

    private let container = CKContainer(identifier: "iCloud.jonahpaul.momentus")
    private var db: CKDatabase { container.privateCloudDatabase }
    private let recordID = CKRecord.ID(recordName: "provider-config-v1")

    private init() {}

    func fetchProviderConfig() async throws -> WatchCloudProviderConfig {
        guard try await container.accountStatus() == .available else {
            throw WatchCloudKitConfigError.iCloudUnavailable
        }

        let record = try await db.record(for: recordID)
        return WatchCloudProviderConfig(
            defaultMode: (record["defaultMode"] as? String) ?? "onDevice",
            assemblyAIAPIKey: (record["assemblyAIAPIKey"] as? String) ?? "",
            anthropicAPIKey: (record["anthropicAPIKey"] as? String) ?? ""
        )
    }
}

enum WatchCloudKitConfigError: LocalizedError {
    case iCloudUnavailable

    var errorDescription: String? {
        switch self {
        case .iCloudUnavailable:
            return "Watch iCloud is not available. Open Momentus on iPhone with your Watch nearby so provider settings can sync directly."
        }
    }
}
