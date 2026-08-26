import Foundation

enum TranscriptChatMode: String, Codable, CaseIterable, Identifiable {
    case onDevice
    case bestQuality

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .onDevice: return "Private"
        case .bestQuality: return "Best Quality"
        }
    }

    var icon: String {
        switch self {
        case .onDevice: return "lock.shield.fill"
        case .bestQuality: return "sparkles"
        }
    }

    var disclosure: String {
        switch self {
        case .onDevice:
            return "Transcript and questions stay on this device."
        case .bestQuality:
            return "Transcript text, chat, and search queries are processed by Momentus Cloud using Anthropic. Audio is never sent for chat."
        }
    }
}

enum TranscriptChatRole: String, Codable {
    case user
    case assistant
}

struct TranscriptChatMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let role: TranscriptChatRole
    var text: String
    let createdAt: Date
    /// Set on assistant messages so the UI can show which provider answered.
    let mode: TranscriptChatMode?

    init(
        id: UUID = UUID(),
        role: TranscriptChatRole,
        text: String,
        createdAt: Date = Date(),
        mode: TranscriptChatMode? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.mode = mode
    }
}

struct TranscriptChatThread: Codable, Equatable {
    let recordingID: UUID
    var messages: [TranscriptChatMessage]
    var updatedAt: Date
}

enum TranscriptChatError: LocalizedError {
    case emptyTranscript
    case missingAnthropicAPIKey
    case onDeviceTranscriptTooLong(estimatedTokens: Int, recommendedMaximum: Int)
    case onDeviceContextLimit
    case onDeviceModelUnavailable
    case emptyResponse
    case providerFailure(String)

    var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            return "This recording does not have enough transcript text to chat with."
        case .missingAnthropicAPIKey:
            return "Best Quality chat is temporarily unavailable because Momentus Cloud is not configured."
        case .onDeviceTranscriptTooLong(let estimatedTokens, let recommendedMaximum):
            return "This transcript is about \(estimatedTokens.formatted()) tokens. Private chat works best below about \(recommendedMaximum.formatted()) tokens."
        case .onDeviceContextLimit:
            return "The on-device model ran out of context for this transcript."
        case .onDeviceModelUnavailable:
            return "Private chat requires Apple Intelligence and its on-device model to be available."
        case .emptyResponse:
            return "The AI returned an empty response. Please try again."
        case .providerFailure(let message):
            return message
        }
    }

    var offersBestQuality: Bool {
        switch self {
        case .onDeviceTranscriptTooLong, .onDeviceContextLimit, .onDeviceModelUnavailable:
            return true
        default:
            return false
        }
    }
}
