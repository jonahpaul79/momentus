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

    init(apiKey: String? = nil, model: String = AnthropicClient.defaultModel) {
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

        var reply = try await client.messageDetailed(
            system: MeetingSummaryPromptBuilder.systemPrompt,
            messages: [.init(role: "user", content: userMessage)],
            model: model,
            maxTokens: 4_096
        )

        if reply.stopReason == "max_tokens" {
            print("[Claude] structured response hit token limit — retrying with a larger output budget")
            reply = try await client.messageDetailed(
                system: MeetingSummaryPromptBuilder.systemPrompt,
                messages: [.init(role: "user", content: userMessage)],
                model: model,
                maxTokens: 8_192
            )
        }

        guard reply.stopReason != "max_tokens",
              reply.stopReason != "model_context_window_exceeded" else {
            throw ClaudeSummaryError.truncatedResponse
        }

        print("[Claude] received \(reply.text.count) chars — \(reply.usage.inputTokens) in / \(reply.usage.outputTokens) out tokens; stop=\(reply.stopReason ?? "unknown")")
        return try parseSummary(from: reply.text, transcript: transcript, recordingId: recordingId)
    }

    // MARK: - JSON Parsing

    private func parseSummary(
        from response: String,
        transcript: Transcript,
        recordingId: UUID
    ) throws -> MeetingSummary {
        let json = extractJSON(from: response)

        if let data = json.data(using: .utf8) {
            if let parsed = try? JSONDecoder().decode(ClaudeOutput.self, from: data) {
                return buildSummary(from: parsed, transcript: transcript, recordingId: recordingId)
            }
            // Retry with normalized top-level keys — Claude sometimes returns inconsistent casing
            if let normalized = normalizeJSONKeys(json),
               let normalizedData = normalized.data(using: .utf8),
               let parsed = try? JSONDecoder().decode(ClaudeOutput.self, from: normalizedData) {
                print("[Claude] decoded with normalized keys")
                return buildSummary(from: parsed, transcript: transcript, recordingId: recordingId)
            }
            do {
                _ = try JSONDecoder().decode(ClaudeOutput.self, from: data)
            } catch {
                print("[Claude] JSON decode failed: \(error.localizedDescription)")
            }
        }

        // Returning a placeholder made a failed Claude response look like a
        // successful regeneration. Throw so the configured summary fallback can
        // produce complete notes instead.
        throw ClaudeSummaryError.invalidStructuredResponse
    }

    // Normalizes common casing/snake-case variations and compact string arrays.
    // A single differently shaped nested item should not invalidate a long result.
    private func normalizeJSONKeys(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let keyMap: [String: String] = [
            "suggestedtitle": "suggestedTitle",
            "executivesummary": "executiveSummary",
            "markedmoments": "markedMoments",
            "actionitems": "actionItems",
            "openquestions": "openQuestions",
            "followupdraft": "followUpDraft",
            "transcriptexcerpt": "transcriptExcerpt",
            "isownerinferred": "isOwnerInferred",
            "decision": "text",
            "question": "text",
            "action": "title",
            "task": "title",
            "responsible": "owner",
        ]

        func canonical(_ key: String) -> String {
            key.unicodeScalars
                .filter { CharacterSet.alphanumerics.contains($0) }
                .map(String.init)
                .joined()
                .lowercased()
        }

        func normalize(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] {
                var output: [String: Any] = [:]
                for (key, nestedValue) in dictionary {
                    let normalizedKey = keyMap[canonical(key)] ?? key
                    output[normalizedKey] = normalize(nestedValue)
                }
                return output
            }
            if let array = value as? [Any] {
                return array.map(normalize)
            }
            return value
        }

        guard var normalized = normalize(obj) as? [String: Any] else { return nil }
        let itemShapes: [(key: String, textKey: String)] = [
            ("markedMoments", "summary"),
            ("decisions", "text"),
            ("actionItems", "title"),
            ("openQuestions", "text"),
            ("risks", "title"),
        ]
        for shape in itemShapes {
            guard let items = normalized[shape.key] as? [Any] else { continue }
            normalized[shape.key] = items.compactMap { item -> [String: Any]? in
                if let text = item as? String { return [shape.textKey: text] }
                guard var dictionary = item as? [String: Any] else { return nil }
                if shape.key == "risks", dictionary["description"] == nil {
                    dictionary["description"] = dictionary["title"] ?? ""
                }
                return dictionary
            }
        }
        guard let out = try? JSONSerialization.data(withJSONObject: normalized),
              let str = String(data: out, encoding: .utf8) else { return nil }
        return str
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
        recordingId: UUID
    ) -> MeetingSummary {
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
            decisions: (output.decisions ?? []).compactMap { d in
                MeetingSummarySanitizer.cleanDecision(
                    text: d.text,
                    context: d.context,
                    confidence: d.confidenceFloat
                )
            },
            actionItems: (output.actionItems ?? []).compactMap { a in
                MeetingSummarySanitizer.cleanActionItem(
                    title: a.title,
                    owner: a.owner,
                    isOwnerInferred: a.isOwnerInferred ?? false,
                    confidence: a.confidenceFloat,
                    priority: a.priorityValue
                )
            },
            openQuestions: (output.openQuestions ?? []).compactMap { q in
                MeetingSummarySanitizer.cleanOpenQuestion(
                    text: q.text,
                    owner: q.owner,
                    priority: q.priorityValue
                )
            },
            risks: (output.risks ?? []).compactMap { r in
                MeetingSummarySanitizer.cleanRisk(
                    title: r.title,
                    description: r.description,
                    severity: r.severityValue
                )
            },
            followUpDraft: output.followUpDraft ?? "Hi team, following up on our meeting.",
            provider: providerName,
            createdAt: Date(),
            confidenceNotes: []
        )
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

        enum CodingKeys: String, CodingKey {
            case suggestedTitle, executiveSummary, markedMoments, decisions, actionItems,
                 openQuestions, risks, followUpDraft
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
    case truncatedResponse
    case invalidStructuredResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Momentus Cloud is not configured for Claude summaries."
        case .truncatedResponse:
            return "The cloud notes response was incomplete."
        case .invalidStructuredResponse:
            return "The cloud notes response was not valid structured data."
        }
    }
}
