import Foundation

/// Formats a Transcript into a readable string for LLM input and builds the
/// system + user prompts for Claude meeting summarization.
///
/// Keep prompts here rather than in ClaudeSummaryService so they can be tuned,
/// versioned, or A/B tested independently of the HTTP layer.
enum MeetingSummaryPromptBuilder {

    // MARK: - System Prompt

    static let systemPrompt = """
        You are a conversation intelligence assistant. You extract structured, accurate information from transcripts of meetings, lectures, interviews, and spoken conversations.

        You must return a single valid JSON object — no text before or after the JSON, no markdown fences.

        JSON schema:
        {
          "suggestedTitle": "string — concise 5-8 word title that describes what the meeting was about",
          "executiveSummary": "string — 2-4 sentences covering what was discussed, what was decided, and what comes next",
          "markedMoments": [
            {
              "timestamp": number — seconds from start of recording,
              "summary": "string — one concise bullet summarizing why this marked moment mattered",
              "transcriptExcerpt": "string or null — short quote or paraphrased excerpt from nearby transcript"
            }
          ],
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
              "title": "string — short concern label",
              "description": "string — the concern, obstacle, or issue raised and why it matters",
              "severity": "critical" | "high" | "medium" | "low"
            }
          ],
          "followUpDraft": "string — a short 2-3 sentence follow-up message or note summarising key outcomes and next steps",
          "confidenceNotes": ["string — any important caveats about transcript quality, speaker attribution, or uncertain content"]
        }

        Rules:
        1. Ground every item in what was actually spoken. Do not invent content.
        2. Leave arrays empty ([]) when the transcript contains nothing explicit for that field. Action items require someone to have explicitly assigned or committed to a task. Open questions require a question to have been explicitly raised and left unresolved. Do not infer either from general discussion.
        3. Only assign an owner if that person was explicitly named in the transcript.
        4. Set isOwnerInferred: true when ownership was implied but not directly stated.
        5. Distinguish explicit decisions from tentative discussion — only populate decisions[] with clear conclusions.
        6. Flag low-confidence or unclear transcript areas in confidenceNotes.
        7. Use concise, professional language. Avoid filler phrases.
        8. Prioritize action items by urgency: high = blocking or time-sensitive, medium = clear next step, low = suggested.
        9. If marked moments are provided, summarize each marked moment explicitly in markedMoments[] using only the nearby transcript context.
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

        let markerContext = formatMarkedMomentContext(for: context.transcript)
        if !markerContext.isEmpty {
            parts.append("")
            parts.append("**User-Marked Moments:**")
            parts.append(markerContext)
            parts.append("Treat these as moments the user intentionally flagged. Summarize them explicitly in markedMoments[].")
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

    static func markerTimestamps(in transcript: Transcript) -> [TimeInterval] {
        guard let raw = transcript.providerData["momentus_markers"], !raw.isEmpty else { return [] }
        return raw
            .split(separator: ",")
            .compactMap { TimeInterval($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .sorted()
    }

    static func fallbackMarkedMoments(from transcript: Transcript) -> [MarkedMoment] {
        markerTimestamps(in: transcript).map { timestamp in
            MarkedMoment(
                timestamp: timestamp,
                summary: "Marked moment at \(formatTimestamp(timestamp))",
                transcriptExcerpt: excerpt(near: timestamp, in: transcript)
            )
        }
    }

    static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }

    // MARK: - Helpers

    private static func formatMarkedMomentContext(for transcript: Transcript) -> String {
        markerTimestamps(in: transcript).map { timestamp in
            let text = excerpt(near: timestamp, in: transcript) ?? "(no nearby transcript text)"
            return "- [\(formatTimestamp(timestamp))] \(text)"
        }
        .joined(separator: "\n")
    }

    private static func excerpt(near timestamp: TimeInterval, in transcript: Transcript) -> String? {
        let window: TimeInterval = 20
        let nearby = transcript.segments.filter { segment in
            segment.endTime >= timestamp - window && segment.startTime <= timestamp + window
        }
        let selected = nearby.isEmpty
            ? transcript.segments.min { abs($0.startTime - timestamp) < abs($1.startTime - timestamp) }.map { [$0] } ?? []
            : nearby
        let text = selected.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
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
