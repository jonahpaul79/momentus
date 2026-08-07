import Foundation

final class ClaudeTranscriptChatService: TranscriptChatService {
    let providerName = "Claude (Anthropic)"
    let isOnDevice = false

    private let client: AnthropicClient

    init(apiKey: String) {
        client = AnthropicClient(apiKey: apiKey)
    }

    func reply(
        to messages: [TranscriptChatMessage],
        transcript: Transcript,
        recordingTitle: String
    ) async throws -> String {
        let formattedTranscript = TranscriptChatPrompt.formattedTranscript(transcript)
        guard !formattedTranscript.isEmpty else { throw TranscriptChatError.emptyTranscript }

        let anthropicMessages = messages.map { message in
            AnthropicClient.Message(
                role: message.role == .user ? "user" : "assistant",
                content: message.text
            )
        }
        let result = try await client.message(
            system: TranscriptChatPrompt.systemInstructions(
                recordingTitle: recordingTitle,
                transcript: formattedTranscript
            ),
            messages: anthropicMessages,
            maxTokens: 1_200
        )
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptChatError.emptyResponse }
        return text
    }
}
