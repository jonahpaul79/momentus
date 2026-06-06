import CloudKit
import Foundation

final class WatchCloudKitRecordingService {
    static let shared = WatchCloudKitRecordingService()

    private let container = CKContainer(identifier: "iCloud.jonahpaul.momentus")
    private var db: CKDatabase { container.privateCloudDatabase }

    private init() {}

    func saveProcessedRecording(
        recordingID: String,
        audioFileURL: URL,
        startedAt: Date,
        endedAt: Date,
        markers: [TimeInterval],
        transcriptText: String,
        summary: WatchCloudSummary?
    ) async -> Bool {
        do {
            guard try await container.accountStatus() == .available else { return false }
            guard let recordingUUID = UUID(uuidString: recordingID) else { return false }

            let recordID = CKRecord.ID(recordName: recordingID)
            let record = CKRecord(recordType: "Recording", recordID: recordID)
            let title = summary?.title ?? Self.title(from: startedAt)
            record["title"] = title
            record["startedAt"] = startedAt
            record["endedAt"] = endedAt
            record["modeRaw"] = "bestQuality"
            record["micSourceRaw"] = "watch"
            record["audioFileID"] = audioFileURL.lastPathComponent
            record["processingStateRaw"] = "completed"
            record["isFavorite"] = Int64(0)
            record["audioAsset"] = CKAsset(fileURL: audioFileURL)

            if let markersData = try? JSONEncoder().encode(markers) {
                record["markersData"] = markersData as NSData
            }
            if let summaryData = try? JSONEncoder().encode(Self.makeSummaryPayload(recordingID: recordingUUID, summary: summary)) {
                record["summaryData"] = summaryData as NSData
            }
            record["transcriptAsset"] = try makeTranscriptAsset(
                recordingID: recordingUUID,
                startedAt: startedAt,
                endedAt: endedAt,
                transcriptText: transcriptText
            )

            try await db.save(record)
            print("[Watch CloudKit] saved processed recording \(recordingID)")
            return true
        } catch {
            print("[Watch CloudKit] save processed recording failed: \(error.localizedDescription)")
            return false
        }
    }

    private func makeTranscriptAsset(
        recordingID: UUID,
        startedAt: Date,
        endedAt: Date,
        transcriptText: String
    ) throws -> CKAsset {
        let speakerID = UUID()
        let transcript = WatchTranscriptPayload(
            id: UUID(),
            recordingId: recordingID,
            segments: [
                WatchTranscriptSegmentPayload(
                    id: UUID(),
                    text: transcriptText,
                    startTime: 0,
                    endTime: max(1, endedAt.timeIntervalSince(startedAt)),
                    speakerId: speakerID,
                    confidence: 0.9,
                    isEdited: false
                )
            ],
            speakers: [
                WatchSpeakerPayload(
                    id: speakerID,
                    name: "Speaker 1",
                    isNameInferred: true,
                    colorHex: "#6366F1"
                )
            ],
            language: "en",
            provider: "AssemblyAI (Watch Cloud)",
            providerData: [:],
            createdAt: Date()
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(recordingID.uuidString + "_watch_transcript.json")
        try JSONEncoder().encode(transcript).write(to: url)
        return CKAsset(fileURL: url)
    }

    private static func makeSummaryPayload(recordingID: UUID, summary: WatchCloudSummary?) -> WatchSummaryPayload {
        WatchSummaryPayload(
            id: UUID(),
            recordingId: recordingID,
            suggestedTitle: summary?.title,
            executiveSummary: summary?.executiveSummary ?? "Summary could not be generated yet. The transcript is available.",
            markedMoments: [],
            decisions: (summary?.decisions ?? []).map {
                WatchDecisionPayload(id: UUID(), text: $0, context: nil, confidence: 0.85)
            },
            actionItems: (summary?.actionItems ?? []).map {
                WatchActionItemPayload(
                    id: UUID(),
                    title: $0.task,
                    owner: $0.owner,
                    isOwnerInferred: false,
                    dueDate: nil,
                    isDueDateInferred: false,
                    isCompleted: false,
                    confidence: 0.85,
                    priority: "medium"
                )
            },
            openQuestions: (summary?.openQuestions ?? []).map {
                WatchOpenQuestionPayload(id: UUID(), text: $0, owner: nil, priority: "medium")
            },
            risks: [],
            followUpDraft: summary?.followUp ?? "Hi team, following up on our recent meeting.",
            provider: summary == nil ? "Watch Cloud Transcript" : "AssemblyAI LeMUR (Watch Cloud)",
            createdAt: Date(),
            confidenceNotes: ["Processed directly from Apple Watch."]
        )
    }

    private static func title(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d h:mm a"
        return "Watch Recording - \(formatter.string(from: date))"
    }
}

private struct WatchTranscriptPayload: Encodable {
    let id: UUID
    let recordingId: UUID
    let segments: [WatchTranscriptSegmentPayload]
    let speakers: [WatchSpeakerPayload]
    let language: String
    let provider: String
    let providerData: [String: String]
    let createdAt: Date
}

private struct WatchTranscriptSegmentPayload: Encodable {
    let id: UUID
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let speakerId: UUID?
    let confidence: Float
    let isEdited: Bool
}

private struct WatchSpeakerPayload: Encodable {
    let id: UUID
    let name: String
    let isNameInferred: Bool
    let colorHex: String
}

private struct WatchSummaryPayload: Encodable {
    let id: UUID
    let recordingId: UUID
    let suggestedTitle: String?
    let executiveSummary: String
    let markedMoments: [WatchMarkedMomentPayload]
    let decisions: [WatchDecisionPayload]
    let actionItems: [WatchActionItemPayload]
    let openQuestions: [WatchOpenQuestionPayload]
    let risks: [WatchRiskPayload]
    let followUpDraft: String
    let provider: String
    let createdAt: Date
    let confidenceNotes: [String]
}

private struct WatchMarkedMomentPayload: Encodable {}
private struct WatchRiskPayload: Encodable {}

private struct WatchDecisionPayload: Encodable {
    let id: UUID
    let text: String
    let context: String?
    let confidence: Float
}

private struct WatchActionItemPayload: Encodable {
    let id: UUID
    let title: String
    let owner: String?
    let isOwnerInferred: Bool
    let dueDate: Date?
    let isDueDateInferred: Bool
    let isCompleted: Bool
    let confidence: Float
    let priority: String
}

private struct WatchOpenQuestionPayload: Encodable {
    let id: UUID
    let text: String
    let owner: String?
    let priority: String
}
