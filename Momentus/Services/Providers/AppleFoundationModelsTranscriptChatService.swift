import Foundation
import FoundationModels

final class AppleFoundationModelsTranscriptChatService: TranscriptChatService {
    let providerName = "Apple Foundation Models"
    let isOnDevice = true

    func reply(
        to messages: [TranscriptChatMessage],
        transcript: Transcript,
        recordingTitle: String
    ) async throws -> String {
        if let preflightError = TranscriptChatPrompt.onDevicePreflightError(for: transcript) {
            throw preflightError
        }
        guard case .available = SystemLanguageModel.default.availability else {
            throw TranscriptChatError.onDeviceModelUnavailable
        }

        let formattedTranscript = TranscriptChatPrompt.formattedTranscript(transcript)
        let session = LanguageModelSession(
            instructions: TranscriptChatPrompt.systemInstructions(
                recordingTitle: recordingTitle,
                transcript: formattedTranscript
            )
        )

        do {
            let response = try await session.respond(to: TranscriptChatPrompt.recentConversation(messages))
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw TranscriptChatError.emptyResponse }
            return text
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize:
                throw TranscriptChatError.onDeviceContextLimit
            case .assetsUnavailable:
                throw TranscriptChatError.onDeviceModelUnavailable
            default:
                throw TranscriptChatError.providerFailure(
                    error.localizedDescription.isEmpty
                        ? "Private chat could not generate a response."
                        : error.localizedDescription
                )
            }
        }
    }
}
