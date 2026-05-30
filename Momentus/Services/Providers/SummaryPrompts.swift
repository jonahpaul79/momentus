import Foundation

/// All prompts used by AI summary providers live here so they can be tuned
/// without touching service logic.
enum SummaryPrompts {

    /// System-level grounding rules sent with every request.
    static let systemInstruction = """
        You summarize spoken recordings — meetings, voice memos, and notes to self.

        Rules:
        1. Ground every claim in the transcript. If it wasn't said, don't include it.
        2. Leave a section empty rather than guessing or padding.
        3. Names, dates, and owners only appear if explicitly spoken.
        4. Match the format to the content — a one-sentence voice memo shouldn't \
        look like a board meeting recap.
        5. Decisions, action items, and open questions are only populated when \
        the transcript clearly contains them.
        """

    /// User turn that wraps the transcript text.
    static func userMessage(transcript: String) -> String {
        "Extract structured information from this recording transcript. If the transcript includes user-marked moments, summarize those moments explicitly:\n\n\(transcript)"
    }
}
