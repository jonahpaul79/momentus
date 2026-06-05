import Foundation

struct WatchCloudProcessingResult {
    let transcriptText: String
    let summary: WatchCloudSummary?
}

struct WatchCloudSummary {
    let title: String?
    let executiveSummary: String
    let decisions: [String]
    let actionItems: [ActionItem]
    let openQuestions: [String]
    let followUp: String?

    struct ActionItem {
        let task: String
        let owner: String?
    }

    var propertyList: [String: Any] {
        var payload: [String: Any] = [
            "executiveSummary": executiveSummary,
            "decisions": decisions,
            "actionItems": actionItems.map { item in
                var dict: [String: String] = ["task": item.task]
                if let owner = item.owner { dict["owner"] = owner }
                return dict
            },
            "openQuestions": openQuestions
        ]
        if let title { payload["title"] = title }
        if let followUp { payload["followUp"] = followUp }
        return payload
    }
}

final class WatchCloudAssemblyAIService {
    private let apiKey: String
    private let baseURL = URL(string: "https://api.assemblyai.com")!
    private let session: URLSession

    init(apiKey: String) {
        self.apiKey = apiKey
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 1800
        self.session = URLSession(configuration: config)
    }

    func process(fileURL: URL) async throws -> WatchCloudProcessingResult {
        let uploadURL = try await upload(fileURL: fileURL)
        let transcriptID = try await createTranscript(uploadURL: uploadURL)
        let transcript = try await pollTranscript(id: transcriptID)
        let text = transcript.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw WatchCloudAssemblyAIError.emptyTranscript }

        let summary = try? await summarize(transcriptID: transcriptID, transcriptText: text)
        return WatchCloudProcessingResult(
            transcriptText: text,
            summary: summary
        )
    }

    private func upload(fileURL: URL) async throws -> String {
        let data = try Data(contentsOf: fileURL)
        var request = URLRequest(url: baseURL.appending(path: "/v2/upload"))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let (responseData, response) = try await session.data(for: request)
        try validate(response, data: responseData)
        return try JSONDecoder().decode(UploadResponse.self, from: responseData).uploadURL
    }

    private func createTranscript(uploadURL: String) async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "/v2/transcript"))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(TranscriptRequest(audioURL: uploadURL))

        let (responseData, response) = try await session.data(for: request)
        try validate(response, data: responseData)
        return try JSONDecoder().decode(TranscriptResponse.self, from: responseData).id
    }

    private func pollTranscript(id: String) async throws -> TranscriptResponse {
        let url = baseURL.appending(path: "/v2/transcript/\(id)")
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")

        for attempt in 0..<120 {
            if attempt > 0 { try await Task.sleep(for: .seconds(5)) }
            let (responseData, response) = try await session.data(for: request)
            try validate(response, data: responseData)
            let transcript = try JSONDecoder().decode(TranscriptResponse.self, from: responseData)
            if transcript.status == "completed" { return transcript }
            if transcript.status == "error" {
                throw WatchCloudAssemblyAIError.providerError(transcript.error ?? "Transcription failed")
            }
        }
        throw WatchCloudAssemblyAIError.timeout
    }

    private func summarize(transcriptID: String, transcriptText: String) async throws -> WatchCloudSummary {
        let prompt = """
        Analyze this meeting transcript and return only a valid JSON object with this exact structure:
        {
          "title": "5-8 word title",
          "executive_summary": "2-4 sentence summary of what was discussed, decided, and what comes next",
          "decisions": ["Explicit decision or conclusion from the meeting"],
          "action_items": [{"task": "Specific next step", "owner": "Person name or null"}],
          "open_questions": ["Explicit unresolved question"],
          "follow_up": "Short 2-3 sentence follow-up note"
        }

        Rules:
        - Do not paste or continue the transcript.
        - Ground every item in what was spoken.
        - Leave arrays empty when there is no explicit evidence.
        - Return JSON only. No markdown fences, no preamble.
        """

        if let parsed = try await requestSummary(
            LeMURRequest(transcriptIDs: [transcriptID], inputText: nil, prompt: prompt)
        ) {
            return parsed
        }

        if let parsed = try await requestSummary(
            LeMURRequest(transcriptIDs: nil, inputText: transcriptText, prompt: prompt)
        ) {
            return parsed
        }

        throw WatchCloudAssemblyAIError.providerError("Summary response was not valid JSON")
    }

    private func requestSummary(_ body: LeMURRequest) async throws -> WatchCloudSummary? {
        var request = URLRequest(url: baseURL.appending(path: "/lemur/v3/generate/task"))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (responseData, response) = try await session.data(for: request)
        try validate(response, data: responseData)
        let responseText = try JSONDecoder().decode(LeMURResponse.self, from: responseData).response
        let jsonText = extractJSON(responseText)
        guard let data = jsonText.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(SummaryResponse.self, from: data)
        else {
            return nil
        }
        return parsed.summaryPayload
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw WatchCloudAssemblyAIError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "HTTP \(http.statusCode)"
            throw WatchCloudAssemblyAIError.providerError(message)
        }
    }

    private func extractJSON(_ text: String) -> String {
        let stripped = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = stripped.firstIndex(of: "{"),
              let end = stripped.lastIndex(of: "}") else { return stripped }
        return String(stripped[start...end])
    }

    private struct UploadResponse: Decodable {
        let uploadURL: String
        enum CodingKeys: String, CodingKey { case uploadURL = "upload_url" }
    }

    private struct TranscriptRequest: Encodable {
        let audioURL: String
        let speechModels = ["universal-3-pro"]
        let speakerLabels = true
        let languageDetection = true
        let punctuate = true
        let formatText = true

        enum CodingKeys: String, CodingKey {
            case audioURL = "audio_url"
            case speechModels = "speech_models"
            case speakerLabels = "speaker_labels"
            case languageDetection = "language_detection"
            case punctuate
            case formatText = "format_text"
        }
    }

    private struct TranscriptResponse: Decodable {
        let id: String
        let status: String
        let text: String?
        let error: String?
    }

    private struct LeMURRequest: Encodable {
        let transcriptIDs: [String]?
        let inputText: String?
        let prompt: String
        let finalModel = "default"
        let maxOutputSize = 1000

        enum CodingKeys: String, CodingKey {
            case transcriptIDs = "transcript_ids"
            case inputText = "input_text"
            case prompt
            case finalModel = "final_model"
            case maxOutputSize = "max_output_size"
        }
    }

    private struct LeMURResponse: Decodable {
        let response: String
    }

    private struct SummaryResponse: Decodable {
        let title: String?
        let executiveSummary: String?
        let summary: String?
        let decisions: [String]?
        let actionItems: [ActionItemResponse]?
        let openQuestions: [String]?
        let followUp: String?

        enum CodingKeys: String, CodingKey {
            case title, summary, decisions
            case executiveSummary = "executive_summary"
            case actionItems = "action_items"
            case openQuestions = "open_questions"
            case followUp = "follow_up"
        }

        var summaryPayload: WatchCloudSummary? {
            let text = (executiveSummary ?? summary ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return WatchCloudSummary(
                title: title.flatMap { Self.cleanedOptional($0) },
                executiveSummary: text,
                decisions: (decisions ?? []).compactMap(Self.cleanedOptional),
                actionItems: (actionItems ?? []).compactMap { item in
                    guard let task = Self.cleanedOptional(item.task) else { return nil }
                    return WatchCloudSummary.ActionItem(
                        task: task,
                        owner: item.owner.flatMap(Self.cleanedOptional)
                    )
                },
                openQuestions: (openQuestions ?? []).compactMap(Self.cleanedOptional),
                followUp: followUp.flatMap(Self.cleanedOptional)
            )
        }

        nonisolated private static func cleanedOptional(_ raw: String) -> String? {
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty || cleaned.lowercased() == "null" ? nil : cleaned
        }

        struct ActionItemResponse: Decodable {
            let task: String
            let owner: String?
        }
    }

    private struct ErrorBody: Decodable {
        let error: String
    }
}

enum WatchCloudAssemblyAIError: LocalizedError {
    case emptyTranscript
    case timeout
    case invalidResponse
    case providerError(String)

    var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            return "AssemblyAI returned an empty transcript."
        case .timeout:
            return "AssemblyAI processing timed out."
        case .invalidResponse:
            return "AssemblyAI returned an unexpected response."
        case .providerError(let message):
            return message
        }
    }
}
