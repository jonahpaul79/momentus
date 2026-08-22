import FoundationModels
import Foundation

final class AppleFoundationModelsSummaryService: ProgressReportingSummaryService {
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
        @Guide(description: "Explicit choices, approvals, commitments, scope calls, or finalized conclusions; empty if none")
        var decisions: [String]
        @Guide(description: "Action items explicitly assigned or committed to in the conversation; empty if none were stated")
        var actionItems: [String]
        @Guide(description: "Questions explicitly raised and left unresolved; empty if none were stated")
        var openQuestions: [String]
        @Guide(description: "Short follow-up note or next-step reminder")
        var followUpDraft: String
    }

    @Generable
    struct ChunkOutput {
        @Guide(description: "A concise factual summary of this portion of the meeting")
        var summary: String
        @Guide(description: "Explicit decisions in this portion; empty if none")
        var decisions: [String]
        @Guide(description: "Explicit action items in this portion; empty if none")
        var actionItems: [String]
        @Guide(description: "Questions left unresolved in this portion; empty if none")
        var openQuestions: [String]
    }

    private static let maximumDirectTranscriptCharacters = 9_000

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
        try await summarize(transcript: transcript, recordingId: recordingId, progress: nil)
    }

    func summarize(
        transcript: Transcript,
        recordingId: UUID,
        progress: (@MainActor @Sendable (OnDeviceSummaryProgress) -> Void)?
    ) async throws -> MeetingSummary {
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

        let markedContext = MeetingSummaryPromptBuilder.fallbackMarkedMoments(from: transcript)
            .map { "- [\(MeetingSummaryPromptBuilder.formatTimestamp($0.timestamp))] \($0.transcriptExcerpt ?? "")" }
            .joined(separator: "\n")
        let identityContext = transcript.speakers.contains(where: \.requiresIdentification)
            ? "Speaker identity is unconfirmed. Private on-device transcription may combine multiple voices under one generic speaker label. Do not guess speaker names or attribute remarks to a named person."
            : "The speaker names in this transcript were confirmed by the user."
        let promptText: String
        if text.count > Self.maximumDirectTranscriptCharacters {
            print("[Summary] long transcript — creating bounded section digests")
            let digest = try await buildLongTranscriptDigest(from: transcript, progress: progress)
            let digestContext = "\(identityContext)\n\nChronological section digests:\n\(digest)"
            promptText = markedContext.isEmpty
                ? digestContext
                : "User-marked moments:\n\(markedContext)\n\n\(digestContext)"
        } else {
            let transcriptContext = "\(identityContext)\n\nTranscript:\n\(text)"
            promptText = markedContext.isEmpty
                ? transcriptContext
                : "User-marked moments:\n\(markedContext)\n\n\(transcriptContext)"
        }
        progress?(OnDeviceSummaryProgress(fraction: 0.9, displayText: "Combining section notes"))
        let session = LanguageModelSession(instructions: SummaryPrompts.systemInstruction)
        let response = try await session.respond(
            to: SummaryPrompts.userMessage(transcript: promptText),
            generating: Output.self
        )
        let output = response.content
        progress?(OnDeviceSummaryProgress(fraction: 1, displayText: "Meeting notes generated"))

        return MeetingSummary(
            id: UUID(),
            recordingId: recordingId,
            suggestedTitle: output.suggestedTitle,
            executiveSummary: output.executiveSummary,
            markedMoments: buildMarkedMoments(from: output.markedMoments, transcript: transcript),
            decisions: output.decisions.compactMap {
                MeetingSummarySanitizer.cleanDecision(text: $0, context: nil, confidence: 0.9)
            },
            actionItems: output.actionItems.compactMap { itemText in
                MeetingSummarySanitizer.cleanActionItem(
                    title: itemText,
                    owner: nil,
                    isOwnerInferred: false,
                    confidence: 0.85,
                    priority: .medium
                )
            },
            openQuestions: output.openQuestions.compactMap {
                MeetingSummarySanitizer.cleanOpenQuestion(text: $0, owner: nil, priority: .medium)
            },
            risks: [],
            followUpDraft: output.followUpDraft,
            provider: providerName,
            createdAt: Date(),
            confidenceNotes: ["Summarized with Apple Foundation Models"]
        )
    }

    private func buildLongTranscriptDigest(
        from transcript: Transcript,
        progress: (@MainActor @Sendable (OnDeviceSummaryProgress) -> Void)?
    ) async throws -> String {
        let chunks = transcriptChunks(transcript.segments, maximumCharacters: Self.maximumDirectTranscriptCharacters)
        var digests: [String] = []
        digests.reserveCapacity(chunks.count)

        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            progress?(OnDeviceSummaryProgress(
                fraction: Double(index) / Double(max(1, chunks.count)) * 0.85,
                displayText: "Summarizing section \(index + 1) of \(chunks.count)"
            ))
            let session = LanguageModelSession(instructions: SummaryPrompts.systemInstruction)
            let response = try await session.respond(
                to: "Analyze only this chronological section (\(index + 1) of \(chunks.count)). Preserve facts and explicit commitments; do not invent missing context.\n\n\(chunk)",
                generating: ChunkOutput.self
            )
            let output = response.content
            let decisions = output.decisions.prefix(8).map { "Decision: \(String($0.prefix(280)))" }
            let actions = output.actionItems.prefix(8).map { "Action: \(String($0.prefix(280)))" }
            let questions = output.openQuestions.prefix(8).map { "Open question: \(String($0.prefix(280)))" }
            let details = ([String(output.summary.prefix(1_200))] + decisions + actions + questions)
                .joined(separator: "\n")
            digests.append("Section \(index + 1):\n\(details)")
            progress?(OnDeviceSummaryProgress(
                fraction: Double(index + 1) / Double(chunks.count) * 0.85,
                displayText: "Summarized section \(index + 1) of \(chunks.count)"
            ))
            print("[Summary] completed section digest \(index + 1)/\(chunks.count)")
        }
        return digests.joined(separator: "\n\n")
    }

    private func transcriptChunks(
        _ segments: [TranscriptSegment],
        maximumCharacters: Int
    ) -> [String] {
        var chunks: [String] = []
        var current = ""

        for segment in segments {
            let timestamp = MeetingSummaryPromptBuilder.formatTimestamp(segment.startTime)
            let line = "[\(timestamp)] \(segment.text)"
            if !current.isEmpty, current.count + line.count + 1 > maximumCharacters {
                chunks.append(current)
                current = ""
            }
            if line.count > maximumCharacters {
                if !current.isEmpty { chunks.append(current); current = "" }
                var remaining = line[...]
                while !remaining.isEmpty {
                    let end = remaining.index(remaining.startIndex, offsetBy: min(maximumCharacters, remaining.count))
                    chunks.append(String(remaining[..<end]))
                    remaining = remaining[end...]
                }
            } else {
                current += current.isEmpty ? line : "\n\(line)"
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
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
