import Foundation

/// Summarizes meeting transcripts using the Anthropic Messages API (Claude Sonnet).
///
/// Architecture:
///   AssemblyAI transcription with speaker labels
///   → ClaudeSummaryService.summarize(transcript:recordingId:)
///   → POST api.anthropic.com/v1/messages with structured JSON prompt
///   → parse response into MeetingSummary
///   → caller saves locally (no backend)
///
/// Provider selection (in ServiceFactory):
///   Claude is the default summary provider for Best Quality mode.
///   AssemblyAI LeMUR is the fallback when no Claude key is configured or Claude fails.
///
/// To swap to a different Claude model, change AnthropicClient.defaultModel.
final class ClaudeSummaryService: SummaryService {
    let providerName: String
    let isOnDevice = false

    private let client: AnthropicClient
    private let model: String

    init(apiKey: String, model: String = AnthropicClient.defaultModel) {
        self.model = model
        self.providerName = "Claude Sonnet (\(model))"
        self.client = AnthropicClient(apiKey: apiKey)
    }

    func summarize(transcript: Transcript, recordingId: UUID) async throws -> MeetingSummary {
        guard !transcript.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AnthropicError.emptyResponse
        }

        let context = MeetingSummaryPromptBuilder.MeetingContext(
            title: "Meeting",
            date: transcript.createdAt,
            duration: transcript.segments.last?.endTime ?? 0,
            speakers: transcript.speakers,
            transcript: transcript
        )

        let userMessage = MeetingSummaryPromptBuilder.userMessage(for: context)
        print("[Claude] sending \(userMessage.count) chars to \(model)")

        let (responseText, usage) = try await client.message(
            system: MeetingSummaryPromptBuilder.systemPrompt,
            user: userMessage,
            model: model,
            maxTokens: 2048
        )

        print("[Claude] received \(responseText.count) chars — \(usage.inputTokens) in / \(usage.outputTokens) out tokens")
        return parseSummary(from: responseText, transcript: transcript, usage: usage, recordingId: recordingId)
    }

    // MARK: - JSON Parsing

    private func parseSummary(
        from response: String,
        transcript: Transcript,
        usage: AnthropicClient.MessageResponse.Usage,
        recordingId: UUID
    ) -> MeetingSummary {
        let json = extractJSON(from: response)

        if let data = json.data(using: .utf8) {
            do {
                let parsed = try JSONDecoder().decode(ClaudeOutput.self, from: data)
                return buildSummary(from: parsed, transcript: transcript, usage: usage, recordingId: recordingId)
            } catch {
                print("[Claude] JSON decode failed: \(error)")
            }
        }

        print("[Claude] JSON parse failed — using extractive fallback")
        return MeetingSummary(
            id: UUID(),
            recordingId: recordingId,
            suggestedTitle: nil,
            executiveSummary: response.prefix(500).trimmingCharacters(in: .whitespacesAndNewlines),
            markedMoments: MeetingSummaryPromptBuilder.fallbackMarkedMoments(from: transcript),
            decisions: [], actionItems: [], openQuestions: [], risks: [],
            followUpDraft: "Hi team, following up on our meeting.",
            provider: providerName,
            createdAt: Date(),
            confidenceNotes: [
                "Claude's response could not be parsed as structured JSON.",
                "Raw response excerpt used as summary.",
                tokenNote(usage)
            ]
        )
    }

    // Strip markdown fences and extract the outermost balanced JSON object.
    // Using lastIndex(of:"}") is wrong — it finds the last *nested* closing brace,
    // truncating the JSON. We walk the string tracking brace depth instead.
    private func extractJSON(from text: String) -> String {
        let stripped = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let startIdx = stripped.firstIndex(of: "{") else { return stripped }

        var depth = 0
        var inString = false
        var escaped = false

        for idx in stripped.indices[startIdx...] {
            let ch = stripped[idx]
            if escaped { escaped = false; continue }
            if ch == "\\" && inString { escaped = true; continue }
            if ch == "\"" { inString.toggle(); continue }
            guard !inString else { continue }
            if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 { return String(stripped[startIdx...idx]) }
            }
        }
        return stripped
    }

    private func buildSummary(
        from output: ClaudeOutput,
        transcript: Transcript,
        usage: AnthropicClient.MessageResponse.Usage,
        recordingId: UUID
    ) -> MeetingSummary {
        var notes = output.confidenceNotes ?? []
        notes.append(tokenNote(usage))
        let markedMoments = (output.markedMoments ?? []).map { moment in
            MarkedMoment(
                timestamp: moment.timestampValue,
                summary: moment.summary,
                transcriptExcerpt: moment.transcriptExcerpt.flatMap { $0.isEmpty ? nil : $0 }
            )
        }

        return MeetingSummary(
            id: UUID(),
            recordingId: recordingId,
            suggestedTitle: output.suggestedTitle.flatMap { $0.isEmpty ? nil : $0 },
            executiveSummary: output.executiveSummary ?? "Meeting processed by Claude.",
            markedMoments: markedMoments.isEmpty ? MeetingSummaryPromptBuilder.fallbackMarkedMoments(from: transcript) : markedMoments,
            decisions: (output.decisions ?? []).map { d in
                Decision(
                    id: UUID(),
                    text: d.text,
                    context: d.context,
                    confidence: d.confidenceFloat
                )
            },
            actionItems: (output.actionItems ?? []).map { a in
                ActionItem(
                    id: UUID(),
                    title: a.title,
                    owner: a.owner.flatMap { $0.isEmpty ? nil : $0 },
                    isOwnerInferred: a.isOwnerInferred ?? false,
                    dueDate: nil,
                    isDueDateInferred: false,
                    isCompleted: false,
                    confidence: a.confidenceFloat,
                    priority: a.priorityValue
                )
            },
            openQuestions: (output.openQuestions ?? []).map { q in
                OpenQuestion(
                    id: UUID(),
                    text: q.text,
                    owner: q.owner.flatMap { $0.isEmpty ? nil : $0 },
                    priority: q.priorityValue
                )
            },
            risks: (output.risks ?? []).map { r in
                Risk(
                    id: UUID(),
                    title: r.title,
                    description: r.description,
                    severity: r.severityValue
                )
            },
            followUpDraft: output.followUpDraft ?? "Hi team, following up on our meeting.",
            provider: providerName,
            createdAt: Date(),
            confidenceNotes: notes
        )
    }

    private func tokenNote(_ usage: AnthropicClient.MessageResponse.Usage) -> String {
        "Model: \(model) · \(usage.inputTokens) input / \(usage.outputTokens) output tokens"
    }

    // MARK: - Decodable Output Shape

    private struct ClaudeOutput: Decodable {
        let suggestedTitle: String?
        let executiveSummary: String?
        let markedMoments: [MarkedMomentOutput]?
        let decisions: [DecisionOutput]?
        let actionItems: [ActionItemOutput]?
        let openQuestions: [QuestionOutput]?
        let risks: [RiskOutput]?
        let followUpDraft: String?
        let confidenceNotes: [String]?

        enum CodingKeys: String, CodingKey {
            case suggestedTitle, executiveSummary, markedMoments, decisions, actionItems,
                 openQuestions, risks, followUpDraft, confidenceNotes
        }

        struct MarkedMomentOutput: Decodable {
            let timestamp: ConfidenceValue?
            let summary: String
            let transcriptExcerpt: String?

            var timestampValue: TimeInterval {
                switch timestamp {
                case .number(let d): return d
                case .string(let s): return TimeInterval(s) ?? 0
                case nil: return 0
                }
            }
        }

        struct DecisionOutput: Decodable {
            let text: String
            let context: String?
            let confidence: ConfidenceValue?

            var confidenceFloat: Float {
                switch confidence {
                case .number(let f): return Float(f)
                case .string(let s): return ConfidenceValue.floatFromString(s)
                case nil: return 0.85
                }
            }
        }

        struct ActionItemOutput: Decodable {
            let title: String
            let owner: String?
            let isOwnerInferred: Bool?
            let priority: String?
            let confidence: ConfidenceValue?

            var confidenceFloat: Float {
                switch confidence {
                case .number(let f): return Float(f)
                case .string(let s): return ConfidenceValue.floatFromString(s)
                case nil: return 0.85
                }
            }

            var priorityValue: ActionItem.Priority {
                switch priority?.lowercased() {
                case "high": return .high
                case "low":  return .low
                default:     return .medium
                }
            }
        }

        struct QuestionOutput: Decodable {
            let text: String
            let owner: String?
            let priority: String?

            var priorityValue: OpenQuestion.Priority {
                switch priority?.lowercased() {
                case "critical": return .critical
                case "high":     return .high
                case "low":      return .low
                default:         return .medium
                }
            }
        }

        struct RiskOutput: Decodable {
            let title: String
            let description: String
            let severity: String?

            var severityValue: Risk.Severity {
                switch severity?.lowercased() {
                case "critical": return .critical
                case "high":     return .high
                case "low":      return .low
                default:         return .medium
                }
            }
        }

        // Handles Claude returning confidence as either a number (0.9) or a string ("high")
        enum ConfidenceValue: Decodable {
            case number(Double)
            case string(String)

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let d = try? container.decode(Double.self) {
                    self = .number(d)
                } else {
                    self = .string((try? container.decode(String.self)) ?? "medium")
                }
            }

            static func floatFromString(_ s: String) -> Float {
                switch s.lowercased() {
                case "high":   return 0.95
                case "medium": return 0.80
                case "low":    return 0.60
                default:
                    return Float(s) ?? 0.80
                }
            }
        }
    }
}

enum ClaudeSummaryError: LocalizedError {
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Anthropic API key missing. Add it in Settings to use Claude summaries."
        }
    }
}
