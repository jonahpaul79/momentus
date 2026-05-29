import Foundation

final class AssemblyAIClient {
    private let apiKey: String
    private let baseURL = URL(string: "https://api.assemblyai.com")!
    private let session: URLSession

    init(apiKey: String) {
        self.apiKey = apiKey
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 1800   // 30 min max for large uploads
        self.session = URLSession(configuration: config)
    }

    // MARK: - Upload

    /// Uploads raw audio bytes to AssemblyAI's CDN. Returns the upload_url used to create a transcript job.
    func upload(fileURL: URL) async throws -> String {
        let data = try Data(contentsOf: fileURL)
        var request = URLRequest(url: baseURL.appending(path: "/v2/upload"))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let (responseData, response) = try await session.data(for: request)
        try validate(response, data: responseData, context: "upload")
        return try decode(AssemblyAIUploadResponse.self, from: responseData).uploadURL
    }

    // MARK: - Transcript

    /// Submits a transcript job. Returns the transcript ID for polling.
    func createTranscript(uploadURL: String) async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "/v2/transcript"))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(AssemblyAITranscriptRequest(audioURL: uploadURL))

        let (responseData, response) = try await session.data(for: request)
        try validate(response, data: responseData, context: "create transcript")
        return try decode(AssemblyAITranscriptResponse.self, from: responseData).id
    }

    /// Polls at 5-second intervals until the transcript job completes or fails.
    /// Times out after ~10 minutes (120 attempts).
    func pollTranscript(id: String) async throws -> AssemblyAITranscriptResponse {
        let url = baseURL.appending(path: "/v2/transcript/\(id)")
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")

        for attempt in 0..<120 {
            if attempt > 0 { try await Task.sleep(for: .seconds(5)) }
            try Task.checkCancellation()

            let (responseData, response) = try await session.data(for: request)
            try validate(response, data: responseData, context: "poll transcript")
            let transcript = try decode(AssemblyAITranscriptResponse.self, from: responseData)

            if transcript.isCompleted { return transcript }
            if transcript.isFailed {
                throw AssemblyAIError.transcriptionFailed(transcript.error ?? "Unknown error from AssemblyAI")
            }
            print("[AssemblyAIClient] attempt \(attempt + 1) — status: \(transcript.status)")
        }
        throw AssemblyAIError.timeout
    }

    // MARK: - LeMUR

    /// Calls LeMUR with either transcript IDs or raw input text. Returns the model's response string.
    func lemurTask(_ lemurRequest: AssemblyAILeMURRequest) async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "/lemur/v3/generate/task"))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(lemurRequest)

        let (responseData, response) = try await session.data(for: request)
        try validate(response, data: responseData, context: "LeMUR task")
        return try decode(AssemblyAILeMURResponse.self, from: responseData).response
    }

    // MARK: - Helpers

    private func validate(_ response: URLResponse, data: Data, context: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AssemblyAIError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(AssemblyAIErrorBody.self, from: data))?.error
                ?? "HTTP \(http.statusCode)"
            print("[AssemblyAIClient] \(context) error \(http.statusCode): \(message)")
            switch http.statusCode {
            case 401: throw AssemblyAIError.unauthorized
            case 429: throw AssemblyAIError.rateLimited
            default:  throw AssemblyAIError.serverError(message)
            }
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw AssemblyAIError.invalidResponse
        }
    }
}

// MARK: - Errors

enum AssemblyAIError: LocalizedError {
    case missingAPIKey
    case unauthorized
    case uploadFailed(String)
    case transcriptionFailed(String)
    case noSpeechDetected
    case timeout
    case rateLimited
    case serverError(String)
    case invalidResponse
    case lemurFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "AssemblyAI API key not configured. Add it in Settings → AI Providers to use Best Quality mode."
        case .unauthorized:
            return "AssemblyAI API key is invalid. Check your key in Settings → AI Providers."
        case .uploadFailed(let msg):
            return "Failed to upload recording: \(msg). Check your internet connection and try again."
        case .transcriptionFailed(let msg):
            return "Transcription failed: \(msg). The recording may be too quiet or contain no speech."
        case .noSpeechDetected:
            return "No speech was detected in the recording."
        case .timeout:
            return "Transcription timed out. The recording may be very long or the service is busy — please try again."
        case .rateLimited:
            return "AssemblyAI rate limit reached. Please wait a moment and try again."
        case .serverError(let msg):
            return "AssemblyAI error: \(msg)"
        case .invalidResponse:
            return "Received an unexpected response from AssemblyAI."
        case .lemurFailed(let msg):
            return "Could not generate meeting notes: \(msg). Your transcript is still saved."
        }
    }
}
