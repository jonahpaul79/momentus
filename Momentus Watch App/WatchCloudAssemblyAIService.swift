import Foundation

struct WatchCloudProcessingResult {
    let transcriptText: String
    let summaryText: String?
    let title: String?
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
            summaryText: summary?.summary,
            title: summary?.title
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

    private func summarize(transcriptID: String, transcriptText: String) async throws -> (title: String?, summary: String) {
        let prompt = """
        Summarize this recording. Return JSON only with:
        {"title":"5-8 word title","summary":"2-4 sentence summary"}
        """
        var request = URLRequest(url: baseURL.appending(path: "/lemur/v3/generate/task"))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(LeMURRequest(transcriptIDs: [transcriptID], inputText: nil, prompt: prompt))

        let (responseData, response) = try await session.data(for: request)
        try validate(response, data: responseData)
        let responseText = try JSONDecoder().decode(LeMURResponse.self, from: responseData).response
        let jsonText = extractJSON(responseText)
        guard let data = jsonText.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(SummaryResponse.self, from: data),
              !parsed.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return (nil, transcriptText)
        }
        return (parsed.title, parsed.summary)
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
        let summary: String
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
