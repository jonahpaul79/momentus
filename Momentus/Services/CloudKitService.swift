import CloudKit
import Foundation

// Handles all reads and writes to the user's private CloudKit database.
// Audio files are never synced — only metadata, summaries, and transcripts.
// Transcripts are stored as CKAsset files to avoid the 1MB per-field limit.
// All methods are fire-and-forget from RecordingsStore's perspective; errors are
// logged but never surfaced to the user (local UserDefaults is the source of truth).
final class CloudKitService {
    static let shared = CloudKitService()
    private init() {}

    private let container = CKContainer(identifier: "iCloud.jonahpaul.momentus")
    private var db: CKDatabase { container.privateCloudDatabase }
    private let recordType = "Recording"

    // MARK: - Availability

    func isAvailable() async -> Bool {
        (try? await container.accountStatus()) == .available
    }

    // MARK: - Write

    func save(_ recording: Recording) async {
        do {
            let record = try makeRecord(from: recording)
            try await db.save(record)
        } catch {
            print("[CloudKit] save \(recording.id): \(error.localizedDescription)")
        }
    }

    func saveAll(_ recordings: [Recording]) async {
        await withTaskGroup(of: Void.self) { group in
            for r in recordings { group.addTask { await self.save(r) } }
        }
    }

    func delete(id: UUID) async {
        do {
            try await db.deleteRecord(withID: CKRecord.ID(recordName: id.uuidString))
        } catch {
            print("[CloudKit] delete \(id): \(error.localizedDescription)")
        }
    }

    // MARK: - Read

    func fetchAll() async throws -> [Recording] {
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        var results: [Recording] = []
        var cursor: CKQueryOperation.Cursor?

        repeat {
            let page: (matchResults: [(CKRecord.ID, Result<CKRecord, Error>)], queryCursor: CKQueryOperation.Cursor?)
            if let c = cursor {
                page = try await db.records(continuingMatchFrom: c)
            } else {
                page = try await db.records(matching: query)
            }
            for (_, result) in page.matchResults {
                if let record = try? result.get(), let r = parseRecord(record) {
                    results.append(r)
                }
            }
            cursor = page.queryCursor
        } while cursor != nil

        return results
    }

    // MARK: - CKRecord → Recording

    private func makeRecord(from recording: Recording) throws -> CKRecord {
        let record = CKRecord(
            recordType: recordType,
            recordID: CKRecord.ID(recordName: recording.id.uuidString)
        )
        record["title"]              = recording.title
        record["startedAt"]          = recording.startedAt
        record["endedAt"]            = recording.endedAt
        record["modeRaw"]            = recording.mode.rawValue
        record["micSourceRaw"]       = recording.micSource.rawValue
        record["audioFileID"]        = recording.audioFileID
        record["processingStateRaw"] = recording.processingState.rawValue
        record["isFavorite"]         = Int64(recording.isFavorite ? 1 : 0)

        if let data = try? JSONEncoder().encode(recording.markers) {
            record["markersData"] = data as NSData
        }
        if let summary = recording.summary,
           let data = try? JSONEncoder().encode(summary) {
            record["summaryData"] = data as NSData
        }
        if let transcript = recording.transcript,
           let data = try? JSONEncoder().encode(transcript) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(recording.id.uuidString + "_transcript.json")
            try data.write(to: url)
            record["transcriptAsset"] = CKAsset(fileURL: url)
        }

        return record
    }

    private func parseRecord(_ record: CKRecord) -> Recording? {
        guard let id       = UUID(uuidString: record.recordID.recordName),
              let title    = record["title"] as? String,
              let startedAt = record["startedAt"] as? Date,
              let modeRaw  = record["modeRaw"] as? String,
              let micRaw   = record["micSourceRaw"] as? String,
              let stateRaw = record["processingStateRaw"] as? String
        else { return nil }

        var transcript: Transcript?
        if let asset = record["transcriptAsset"] as? CKAsset,
           let url = asset.fileURL,
           let data = try? Data(contentsOf: url) {
            transcript = try? JSONDecoder().decode(Transcript.self, from: data)
        }

        var summary: MeetingSummary?
        if let data = record["summaryData"] as? NSData {
            summary = try? JSONDecoder().decode(MeetingSummary.self, from: data as Data)
        }

        let markers = (record["markersData"] as? NSData).flatMap {
            try? JSONDecoder().decode([TimeInterval].self, from: $0 as Data)
        } ?? []

        return Recording(
            id: id,
            title: title,
            startedAt: startedAt,
            endedAt: record["endedAt"] as? Date,
            mode: RecordingMode(rawValue: modeRaw) ?? .onDevice,
            micSource: MicSource(rawValue: micRaw) ?? .iPhone,
            audioFileID: record["audioFileID"] as? String,
            processingState: ProcessingState(rawValue: stateRaw) ?? .completed,
            transcript: transcript,
            summary: summary,
            isFavorite: (record["isFavorite"] as? Int64) == 1,
            markers: markers
        )
    }
}
