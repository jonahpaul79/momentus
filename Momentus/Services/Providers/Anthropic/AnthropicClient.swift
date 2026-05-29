import Foundation

/// Lightweight URLSession-based client for the Anthropic Messages API.
/// No third-party SDK — keeps the build simple.
final class AnthropicClient {

    // MARK: - Model Constants

    /// Default model for Best Quality summaries.
    nonisolated static let defaultModel = "claude-sonnet-4-6"
    // TODO: add nonisolated static let haikuModel = "claude-haiku-4-5-20251001"  for lower-cost summary mode
    // TODO: add nonisolated static let opusModel  = "claude-opus-4-8"            for highest-quality mode

    // MARK: - Init

    private let apiKey: String
    private let baseURL = URL(string: "https://api.anthropic.com")!
    private let session: URLSession

    init(apiKey: String) {
        self.apiKey = apiKey
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    // MARK: - Messages

    struct MessageRequest: Encodable {
        let model: String
        let maxTokens: Int
        let system: String
        let messages: [Message]

        enum CodingKeys: String, CodingKey {
            case model, system, messages
            case maxTokens = "max_tokens"
        }

        struct Message: Encodable {
            let role: String
            let content: String
        }
    }

    struct MessageResponse: Decodable {
        let id: String
        let model: String
        let content: [ContentBlock]
        let usage: Usage

        struct ContentBlock: Decodable {
            let type: String
            let text: String?
        }

        struct Usage: Decodable {
            let inputTokens: Int
            let outputTokens: Int

            enum CodingKeys: String, CodingKey {
                case inputTokens  = "input_tokens"
                case outputTokens = "output_tokens"
            }
        }

        var firstText: String? {
            content.first(where: { $0.type == "text" })?.text
        }
    }

    struct ErrorResponse: Decodable {
        let error: ErrorDetail
        struct ErrorDetail: Decodable {
            let type: String
            let message: String
        }
    }

    /// Sends a single-turn message and returns the assistant's text reply.
    func message(
        system: String,
        user: String,
        model: String = AnthropicClient.defaultModel,
        maxTokens: Int = 2048
    ) async throws -> (text: String, usage: MessageResponse.Usage) {
        let body = MessageRequest(
            model: model,
            maxTokens: maxTokens,
            system: system,
            messages: [.init(role: "user", content: user)]
        )

        var request = URLRequest(url: baseURL.appending(path: "/v1/messages"))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)

        let decoded = try decode(MessageResponse.self, from: data)
        guard let text = decoded.firstText else {
            throw AnthropicError.emptyResponse
        }
        return (text, decoded.usage)
    }

    // MARK: - Helpers

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AnthropicError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error.message
                ?? "HTTP \(http.statusCode)"
            print("[AnthropicClient] error \(http.statusCode): \(detail)")
            if detail.localizedCaseInsensitiveContains("credit balance") {
                throw AnthropicError.insufficientCredits
            }
            switch http.statusCode {
            case 401: throw AnthropicError.unauthorized
            case 429: throw AnthropicError.rateLimited
            case 529: throw AnthropicError.overloaded
            default:  throw AnthropicError.serverError(detail)
            }
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw AnthropicError.invalidResponse
        }
    }
}

// MARK: - Errors

enum AnthropicError: LocalizedError {
    case missingAPIKey
    case unauthorized
    case insufficientCredits
    case rateLimited
    case overloaded
    case emptyResponse
    case serverError(String)
    case invalidResponse
    case jsonParsingFailed

    static let billingURL = URL(string: "https://console.anthropic.com/settings/billing")!

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Anthropic API key not configured. Add it in Settings → Best Quality to use Claude summaries."
        case .unauthorized:
            return "Anthropic API key is invalid. Check your key in Settings → Best Quality."
        case .insufficientCredits:
            return "Claude credit balance is too low. Add credits at console.anthropic.com/settings/billing to resume AI summaries."
        case .rateLimited:
            return "Claude rate limit reached. Please wait a moment and try again."
        case .overloaded:
            return "Claude is temporarily overloaded. Please try again in a moment."
        case .emptyResponse:
            return "Claude returned an empty response."
        case .serverError(let msg):
            return "Anthropic error: \(msg)"
        case .invalidResponse:
            return "Received an unexpected response from Anthropic."
        case .jsonParsingFailed:
            return "Could not parse Claude's response as structured notes."
        }
    }
}
