import Foundation

final class AssemblyAISummaryService: SummaryService {
    let providerName = "AssemblyAI LeMUR"
    let isOnDevice = false

    private let client: AssemblyAIClient

    init(apiKey: String) {
        self.client = AssemblyAIClient(apiKey: apiKey)
    }

    func summarize(transcript: Transcript, recordingId: UUID) async throws -> MeetingSummary {
        // Prefer calling LeMUR with the AssemblyAI transcript ID so LeMUR can access
        // the full word-level data. Fall back to sending the transcript text directly
        // if the ID is not available (e.g. when paired with a non-AssemblyAI transcriber).
        let request: AssemblyAILeMURRequest
        if let transcriptID = transcript.providerData["assemblyai_transcript_id"] {
            print("[AssemblyAI LeMUR] using transcript_id \(transcriptID)")
            request = .withTranscriptIDs([transcriptID], prompt: lemurPrompt)
        } else {
            let text = transcript.fullText
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AssemblyAIError.lemurFailed("Transcript is empty")
            }
            print("[AssemblyAI LeMUR] no transcript_id — sending input_text (\(text.count) chars)")
            request = .withInputText(text, prompt: lemurPrompt)
        }

        let responseText = try await client.lemurTask(request)
        print("[AssemblyAI LeMUR] response received (\(responseText.count) chars)")
        return parseSummary(from: responseText, transcript: transcript, recordingId: recordingId)
    }

    // MARK: - JSON Parsing

    private func parseSummary(from response: String, transcript: Transcript, recordingId: UUID) -> MeetingSummary {
        let json = extractJSON(from: response)
        if let data = json.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(LeMUROutput.self, from: data) {
            print("[AssemblyAI LeMUR] JSON parsed — \(parsed.actionItems?.count ?? 0) action items")
            return buildSummary(from: parsed, recordingId: recordingId)
        }
        print("[AssemblyAI LeMUR] JSON parse failed — using extractive fallback")
        return extractiveFallback(transcript: transcript, recordingId: recordingId)
    }

    // Strip markdown code fences and find the outermost JSON object.
    private func extractJSON(from text: String) -> String {
        let stripped = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = stripped.firstIndex(of: "{"),
           let end = stripped.lastIndex(of: "}") {
            return String(stripped[start...end])
        }
        return stripped
    }

    private func buildSummary(from output: LeMUROutput, recordingId: UUID) -> MeetingSummary {
        MeetingSummary(
            id: UUID(),
            recordingId: recordingId,
            suggestedTitle: output.title.flatMap { $0.isEmpty ? nil : $0 },
            executiveSummary: output.summary ?? "Meeting processed by AssemblyAI LeMUR.",
            decisions: (output.decisions ?? []).map {
                Decision(id: UUID(), text: $0, context: nil, confidence: 0.9)
            },
            actionItems: (output.actionItems ?? []).map { item in
                ActionItem(
                    id: UUID(),
                    title: item.task,
                    owner: item.owner.flatMap { $0.isEmpty ? nil : $0 },
                    isOwnerInferred: false,
                    dueDate: nil,
                    isDueDateInferred: false,
                    isCompleted: false,
                    confidence: 0.85,
                    priority: .medium
                )
            },
            openQuestions: (output.openQuestions ?? []).map {
                OpenQuestion(id: UUID(), text: $0, owner: nil, priority: .medium)
            },
            risks: [],
            followUpDraft: output.followUp ?? "Hi team, following up on our meeting.",
            provider: providerName,
            createdAt: Date(),
            confidenceNotes: ["Summarized with AssemblyAI LeMUR"]
        )
    }

    private func extractiveFallback(transcript: Transcript, recordingId: UUID) -> MeetingSummary {
        let sentences = transcript.fullText.components(separatedBy: ". ")
        let preview = sentences.prefix(3).joined(separator: ". ")
        return MeetingSummary(
            id: UUID(), recordingId: recordingId,
            suggestedTitle: nil,
            executiveSummary: preview.isEmpty ? "Meeting processed." : preview + ".",
            decisions: [], actionItems: [], openQuestions: [], risks: [],
            followUpDraft: "Hi team, following up on our recent meeting.",
            provider: providerName, createdAt: Date(),
            confidenceNotes: [
                "LeMUR response could not be parsed as structured JSON.",
                "Raw transcript text was used for the summary."
            ]
        )
    }

    // MARK: - LeMUR Prompt

    // Keep the prompt in the service so it can be tuned independently per provider.
    private let lemurPrompt = """
        Analyze this meeting transcript and return a JSON object with exactly this structure:
        {
          "title": "5-8 word meeting title",
          "summary": "2-4 sentence executive summary of what was discussed and decided",
          "decisions": ["Decision or conclusion reached in the meeting"],
          "action_items": [
            {"task": "Specific action item description", "owner": "Person name or null"}
          ],
          "open_questions": ["Unresolved question from the meeting"],
          "follow_up": "Short 2-3 sentence follow-up email draft"
        }

        Rules:
        - Ground every item in what was actually spoken. Do not invent or assume anything.
        - Leave arrays empty ([]) if the transcript contains nothing relevant for that field.
        - Only include a name as action_item owner if that person was explicitly mentioned.
        - Return only the JSON object — no preamble, no explanation, no markdown fences.
        """

    // MARK: - Decodable Output Shape

    private struct LeMUROutput: Decodable {
        let title: String?
        let summary: String?
        let decisions: [String]?
        let actionItems: [ActionItemOutput]?
        let openQuestions: [String]?
        let followUp: String?

        enum CodingKeys: String, CodingKey {
            case title, summary, decisions
            case actionItems = "action_items"
            case openQuestions = "open_questions"
            case followUp = "follow_up"
        }

        struct ActionItemOutput: Decodable {
            let task: String
            let owner: String?
        }
    }
}
