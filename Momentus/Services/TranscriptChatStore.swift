import Foundation

/// Chat history is deliberately separate from Recording so it remains private,
/// local-only data and does not enter the existing CloudKit recording sync path.
final class TranscriptChatStore {
    private let defaults: UserDefaults
    private let keyPrefix: String

    init(defaults: UserDefaults = .standard, keyPrefix: String = "transcript_chat_thread_") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    func load(recordingID: UUID) -> TranscriptChatThread {
        guard let data = defaults.data(forKey: key(for: recordingID)),
              let thread = try? JSONDecoder().decode(TranscriptChatThread.self, from: data)
        else {
            return TranscriptChatThread(recordingID: recordingID, messages: [], updatedAt: Date())
        }
        return thread
    }

    func save(_ thread: TranscriptChatThread) {
        guard let data = try? JSONEncoder().encode(thread) else { return }
        defaults.set(data, forKey: key(for: thread.recordingID))
    }

    func delete(recordingID: UUID) {
        defaults.removeObject(forKey: key(for: recordingID))
    }

    private func key(for recordingID: UUID) -> String {
        keyPrefix + recordingID.uuidString
    }
}
