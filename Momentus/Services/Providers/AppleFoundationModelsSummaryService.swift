import FoundationModels
import Foundation

final class AppleFoundationModelsSummaryService: SummaryService {
    let providerName = "Apple Foundation Models"
    let isOnDevice = true

    @Generable
    struct Output {
        @Guide(description: "Concise 5-8 word title")
        var suggestedTitle: String
        @Guide(description: "2-3 sentence summary")
        var executiveSummary: String
        @Guide(description: "Decisions or conclusions reached; empty if none")
        var decisions: [String]
        @Guide(description: "Action items with owner only if name was spoken; empty if none")
        var actionItems: [String]
        @Guide(description: "Unresolved questions; empty if none")
        var openQuestions: [String]
        @Guide(description: "Short follow-up note or next-step reminder")
        var followUpDraft: String
    }

    private static let useFallback: Bool = {
        let isSimulator = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil
        let isMac = ProcessInfo.processInfo.isiOSAppOnMac
        return isSimulator || isMac
    }()

    func summarize(transcript: Transcript, recordingId: UUID) async throws -> MeetingSummary {
        print("[Summary] summarize called, segments: \(transcript.segments.count), chars: \(transcript.fullText.count), useFallback=\(Self.useFallback)")
        let text = transcript.fullText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Require real spoken content. Stub/placeholder text and short transcripts
        // cause Foundation Models to hallucinate entire fake meetings.
        let isPlaceholder = text.hasPrefix("[")
        if Self.useFallback || text.count < 50 || isPlaceholder {
            print("[Summary] fallback path (useFallback=\(Self.useFallback), chars=\(text.count), placeholder=\(isPlaceholder))")
            return extractiveSummary(from: transcript, text: text, recordingId: recordingId)
        }

        guard case .available = SystemLanguageModel.default.availability else {
            throw FoundationModelsSummaryError.modelUnavailable
        }

        let session = LanguageModelSession(instructions: SummaryPrompts.systemInstruction)
        let response = try await session.respond(
            to: SummaryPrompts.userMessage(transcript: text),
            generating: Output.self
        )
        let output = response.content

        return MeetingSummary(
            id: UUID(),
            recordingId: recordingId,
            suggestedTitle: output.suggestedTitle,
            executiveSummary: output.executiveSummary,
            decisions: output.decisions.map {
                Decision(id: UUID(), text: $0, context: nil, confidence: 0.9)
            },
            actionItems: output.actionItems.map { itemText in
                ActionItem(
                    id: UUID(),
                    title: itemText,
                    owner: nil,
                    isOwnerInferred: false,
                    dueDate: nil,
                    isDueDateInferred: false,
                    isCompleted: false,
                    confidence: 0.85,
                    priority: .medium
                )
            },
            openQuestions: output.openQuestions.map {
                OpenQuestion(id: UUID(), text: $0, owner: nil, priority: .medium)
            },
            risks: [],
            followUpDraft: output.followUpDraft,
            provider: providerName,
            createdAt: Date(),
            confidenceNotes: ["Summarized with Apple Foundation Models"]
        )
    }

    // Simple sentence-extraction fallback used in the simulator.
    private func extractiveSummary(from transcript: Transcript, text: String, recordingId: UUID) -> MeetingSummary {
        let sentences = text.components(separatedBy: ". ")
        let preview = sentences.prefix(3).joined(separator: ". ")
            + (sentences.count > 3 ? "." : "")

        let f = DateFormatter()
        f.dateFormat = "MMM d 'at' h:mm a"
        let title = "Meeting — \(f.string(from: Date()))"

        return MeetingSummary(
            id: UUID(),
            recordingId: recordingId,
            suggestedTitle: title,
            executiveSummary: preview.isEmpty ? "No transcript content available." : preview,
            decisions: [],
            actionItems: [],
            openQuestions: [],
            risks: [],
            followUpDraft: "Hi team, following up on our meeting today.",
            provider: "\(providerName) (Simulator)",
            createdAt: Date(),
            confidenceNotes: ["Running on simulator — Foundation Models unavailable. Deploy to device for AI-generated summaries."]
        )
    }
}

enum FoundationModelsSummaryError: LocalizedError {
    case modelUnavailable
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .modelUnavailable:
            return "Apple Foundation Models requires Apple Intelligence (iPhone 15 Pro or later with iOS 26)."
        case .emptyTranscript:
            return "The transcript is empty — nothing to summarize."
        }
    }
}
