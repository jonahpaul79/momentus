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
        @Guide(description: "Bullet summaries of user-marked moments; empty if none")
        var markedMoments: [String]
        @Guide(description: "Decisions or conclusions reached; empty if none")
        var decisions: [String]
        @Guide(description: "Action items explicitly assigned or committed to in the conversation; empty if none were stated")
        var actionItems: [String]
        @Guide(description: "Questions explicitly raised and left unresolved; empty if none were stated")
        var openQuestions: [String]
        @Guide(description: "Short follow-up note or next-step reminder")
        var followUpDraft: String
    }

    private static let useFallback: Bool = {
        let isSimulator = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil
        let isMac = ProcessInfo.processInfo.isiOSAppOnMac
        return isSimulator || isMac
    }()
    private static let isSimulatorOrMac: Bool = {
        ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil
        || ProcessInfo.processInfo.isiOSAppOnMac
    }()

    func summarize(transcript: Transcript, recordingId: UUID) async throws -> MeetingSummary {
        print("[Summary] summarize called, segments: \(transcript.segments.count), chars: \(transcript.fullText.count), useFallback=\(Self.useFallback)")
        let text = transcript.fullText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Require real spoken content. Stub/placeholder text and short transcripts
        // cause Foundation Models to hallucinate entire fake meetings.
        let isPlaceholder = text.hasPrefix("[")
        let isTooShortForGeneration = text.count < 50
        if Self.useFallback || isTooShortForGeneration || isPlaceholder {
            let reason: ExtractiveFallbackReason
            if Self.isSimulatorOrMac {
                reason = .simulator
            } else if isTooShortForGeneration {
                reason = .shortTranscript
            } else {
                reason = .placeholderTranscript
            }
            print("[Summary] fallback path (reason=\(reason.logValue), useFallback=\(Self.useFallback), chars=\(text.count), placeholder=\(isPlaceholder))")
            return extractiveSummary(from: transcript, text: text, recordingId: recordingId, reason: reason)
        }

        guard case .available = SystemLanguageModel.default.availability else {
            throw FoundationModelsSummaryError.modelUnavailable
        }

        let session = LanguageModelSession(instructions: SummaryPrompts.systemInstruction)
        let markedContext = MeetingSummaryPromptBuilder.fallbackMarkedMoments(from: transcript)
            .map { "- [\(MeetingSummaryPromptBuilder.formatTimestamp($0.timestamp))] \($0.transcriptExcerpt ?? "")" }
            .joined(separator: "\n")
        let promptText = markedContext.isEmpty
            ? text
            : "User-marked moments:\n\(markedContext)\n\nTranscript:\n\(text)"
        let response = try await session.respond(
            to: SummaryPrompts.userMessage(transcript: promptText),
            generating: Output.self
        )
        let output = response.content

        return MeetingSummary(
            id: UUID(),
            recordingId: recordingId,
            suggestedTitle: output.suggestedTitle,
            executiveSummary: output.executiveSummary,
            markedMoments: buildMarkedMoments(from: output.markedMoments, transcript: transcript),
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
    private func extractiveSummary(
        from transcript: Transcript,
        text: String,
        recordingId: UUID,
        reason: ExtractiveFallbackReason
    ) -> MeetingSummary {
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
            markedMoments: MeetingSummaryPromptBuilder.fallbackMarkedMoments(from: transcript),
            decisions: [],
            actionItems: [],
            openQuestions: [],
            risks: [],
            followUpDraft: "Hi team, following up on our meeting today.",
            provider: reason.providerName(base: providerName),
            createdAt: Date(),
            confidenceNotes: [reason.confidenceNote]
        )
    }

    private func buildMarkedMoments(from summaries: [String], transcript: Transcript) -> [MarkedMoment] {
        let timestamps = MeetingSummaryPromptBuilder.markerTimestamps(in: transcript)
        guard !timestamps.isEmpty else { return [] }
        return timestamps.enumerated().map { index, timestamp in
            MarkedMoment(
                timestamp: timestamp,
                summary: summaries.indices.contains(index) ? summaries[index] : "Marked moment at \(MeetingSummaryPromptBuilder.formatTimestamp(timestamp))",
                transcriptExcerpt: MeetingSummaryPromptBuilder.fallbackMarkedMoments(from: transcript)
                    .first { abs($0.timestamp - timestamp) < 0.1 }?
                    .transcriptExcerpt
            )
        }
    }

    private enum ExtractiveFallbackReason {
        case simulator
        case shortTranscript
        case placeholderTranscript

        var logValue: String {
            switch self {
            case .simulator: return "simulator"
            case .shortTranscript: return "shortTranscript"
            case .placeholderTranscript: return "placeholderTranscript"
            }
        }

        var confidenceNote: String {
            switch self {
            case .simulator:
                return "Running on simulator — Foundation Models unavailable. Deploy to device for AI-generated summaries."
            case .shortTranscript:
                return "Transcript was too short for reliable AI notes, so the summary mirrors the transcript."
            case .placeholderTranscript:
                return "Transcript did not contain enough spoken content for reliable AI notes."
            }
        }

        func providerName(base: String) -> String {
            switch self {
            case .simulator:
                return "\(base) (Simulator)"
            case .shortTranscript, .placeholderTranscript:
                return "Extractive Summary"
            }
        }
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
