import Foundation

/// Formats a Transcript into a readable string for LLM input and builds the
/// system + user prompts for Claude meeting summarization.
///
/// Keep prompts here rather than in ClaudeSummaryService so they can be tuned,
/// versioned, or A/B tested independently of the HTTP layer.
enum MeetingSummaryPromptBuilder {

    // MARK: - System Prompt

    static let systemPrompt = """
        You are a meeting intelligence assistant. You extract structured, accurate information from spoken meeting transcripts.

        You must return a single valid JSON object — no text before or after the JSON, no markdown fences.

        JSON schema:
        {
          "suggestedTitle": "string — concise 5-8 word title that describes what the meeting was about",
          "executiveSummary": "string — 2-4 sentences covering what was discussed, what was decided, and what comes next",
          "decisions": [
            {
              "text": "string — the decision or conclusion",
              "context": "string or null — brief supporting context or evidence from the transcript",
              "confidence": number — 0.0-1.0
            }
          ],
          "actionItems": [
            {
              "title": "string — what needs to be done",
              "owner": "string or null — person responsible",
              "isOwnerInferred": boolean — true if owner was implied, not directly assigned,
              "priority": "high" | "medium" | "low",
              "confidence": number — 0.0-1.0
            }
          ],
          "openQuestions": [
            {
              "text": "string — the unresolved question",
              "owner": "string or null — who is responsible for answering it",
              "priority": "critical" | "high" | "medium" | "low"
            }
          ],
          "risks": [
            {
              "title": "string — short risk label",
              "description": "string — what could go wrong and why it matters",
              "severity": "critical" | "high" | "medium" | "low"
            }
          ],
          "followUpDraft": "string — a short 2-3 sentence follow-up email the organizer could send after the meeting",
          "confidenceNotes": ["string — any important caveats about transcript quality, speaker attribution, or uncertain content"]
        }

        Rules:
        1. Ground every item in what was actually spoken. Do not invent content.
        2. Leave arrays empty ([]) when the transcript contains nothing relevant for that field.
        3. Only assign an owner if that person was explicitly named in the transcript.
        4. Set isOwnerInferred: true when ownership was implied but not directly stated.
        5. Distinguish explicit decisions from tentative discussion — only populate decisions[] with clear conclusions.
        6. Flag low-confidence or unclear transcript areas in confidenceNotes.
        7. Use concise, professional language. Avoid filler phrases.
        8. Prioritize action items by urgency: high = blocking or time-sensitive, medium = clear next step, low = suggested.
        """

    // MARK: - User Message

    struct MeetingContext {
        var title: String
        var date: Date
        var duration: TimeInterval
        var speakers: [Speaker]
        var transcript: Transcript
    }

    static func userMessage(for context: MeetingContext) -> String {
        var parts: [String] = []

        // Meeting metadata header
        let dateStr = DateFormatter.meetingDate.string(from: context.date)
        let durationStr = context.duration.shortString
        parts.append("**Meeting:** \(context.title)")
        parts.append("**Date:** \(dateStr)")
        parts.append("**Duration:** \(durationStr)")

        if !context.speakers.isEmpty {
            let names = context.speakers.map(\.name).joined(separator: ", ")
            parts.append("**Participants:** \(names)")
        }

        parts.append("")
        parts.append("**Transcript:**")
        parts.append(formatTranscript(context.transcript))

        return parts.joined(separator: "\n")
    }

    // MARK: - Transcript Formatter

    /// Converts a Transcript into a timestamped, speaker-labeled text block.
    /// Format: [MM:SS] Speaker Name: text
    /// Low-confidence segments are prefixed with [LOW CONFIDENCE].
    static func formatTranscript(_ transcript: Transcript) -> String {
        guard !transcript.segments.isEmpty else {
            return transcript.fullText.isEmpty ? "(empty transcript)" : transcript.fullText
        }

        let speakerMap = Dictionary(uniqueKeysWithValues: transcript.speakers.map { ($0.id, $0) })

        let lines = transcript.segments.map { segment -> String in
            let timestamp = formatTimestamp(segment.startTime)
            let speakerName = segment.speakerId.flatMap { speakerMap[$0]?.name } ?? "Unknown"
            let confidencePrefix = segment.isLowConfidence ? "[LOW CONFIDENCE] " : ""
            return "\(confidencePrefix)[\(timestamp)] \(speakerName): \(segment.text)"
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}

private extension DateFormatter {
    static let meetingDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f
    }()
}
