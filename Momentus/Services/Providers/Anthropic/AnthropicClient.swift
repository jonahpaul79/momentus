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

    private let apiKey: String?
    private let baseURL = URL(string: "https://api.anthropic.com")!
    private let session: URLSession

    init(apiKey: String? = nil) {
        self.apiKey = apiKey
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    // MARK: - Messages

    enum JSONValue: Codable, Equatable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case object([String: JSONValue])
        case array([JSONValue])
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else if let value = try? container.decode([String: JSONValue].self) {
                self = .object(value)
            } else if let value = try? container.decode([JSONValue].self) {
                self = .array(value)
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unsupported JSON value"
                )
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .bool(let value): try container.encode(value)
            case .object(let value): try container.encode(value)
            case .array(let value): try container.encode(value)
            case .null: try container.encodeNil()
            }
        }

        nonisolated var objectValue: [String: JSONValue]? {
            guard case .object(let value) = self else { return nil }
            return value
        }

        nonisolated var arrayValue: [JSONValue]? {
            guard case .array(let value) = self else { return nil }
            return value
        }

        nonisolated var stringValue: String? {
            guard case .string(let value) = self else { return nil }
            return value
        }
    }

    struct MessageRequest: Encodable {
        let model: String
        let maxTokens: Int
        let system: String
        let messages: [Message]
        let tools: [Tool]?

        init(
            model: String,
            maxTokens: Int,
            system: String,
            messages: [Message],
            tools: [Tool]? = nil
        ) {
            self.model = model
            self.maxTokens = maxTokens
            self.system = system
            self.messages = messages
            self.tools = tools
        }

        enum CodingKeys: String, CodingKey {
            case model, system, messages, tools
            case maxTokens = "max_tokens"
        }

        struct Message: Encodable {
            let role: String
            let content: Content

            init(role: String, content: String) {
                self.role = role
                self.content = .text(content)
            }

            init(role: String, contentBlocks: [JSONValue]) {
                self.role = role
                self.content = .blocks(contentBlocks)
            }

            enum Content: Encodable {
                case text(String)
                case blocks([JSONValue])

                func encode(to encoder: Encoder) throws {
                    var container = encoder.singleValueContainer()
                    switch self {
                    case .text(let text): try container.encode(text)
                    case .blocks(let blocks): try container.encode(blocks)
                    }
                }
            }
        }

        struct Tool: Encodable {
            let type: String
            let name: String
            let maxUses: Int

            enum CodingKeys: String, CodingKey {
                case type, name
                case maxUses = "max_uses"
            }

            static func webSearch(maxUses: Int) -> Tool {
                Tool(type: "web_search_20250305", name: "web_search", maxUses: maxUses)
            }
        }
    }

    typealias Message = MessageRequest.Message

    struct MessageResponse: Decodable {
        let id: String
        let model: String
        let content: [JSONValue]
        let usage: Usage
        let stopReason: String?

        enum CodingKeys: String, CodingKey {
            case id, model, content, usage
            case stopReason = "stop_reason"
        }

        struct Usage: Decodable {
            let inputTokens: Int
            let outputTokens: Int
            let serverToolUse: ServerToolUse?

            enum CodingKeys: String, CodingKey {
                case inputTokens  = "input_tokens"
                case outputTokens = "output_tokens"
                case serverToolUse = "server_tool_use"
            }

            struct ServerToolUse: Decodable {
                let webSearchRequests: Int?

                enum CodingKeys: String, CodingKey {
                    case webSearchRequests = "web_search_requests"
                }
            }

            init(inputTokens: Int, outputTokens: Int, serverToolUse: ServerToolUse? = nil) {
                self.inputTokens = inputTokens
                self.outputTokens = outputTokens
                self.serverToolUse = serverToolUse
            }
        }

        var firstText: String? {
            textBlocks.first?.text
        }

        var allText: String {
            textBlocks.map(\.text).joined(separator: "\n\n")
        }

        var webSearchRequestCount: Int {
            usage.serverToolUse?.webSearchRequests ?? 0
        }

        var renderedWebSearchText: String {
            var citations: [WebCitation] = []
            var citationIndexByURL: [String: Int] = [:]
            var renderedBlocks: [String] = []

            for block in textBlocks {
                var markerIndexes: [Int] = []
                for citation in block.citations where citation.safeURL != nil {
                    if let existing = citationIndexByURL[citation.url] {
                        markerIndexes.append(existing)
                    } else {
                        citations.append(citation)
                        let index = citations.count
                        citationIndexByURL[citation.url] = index
                        markerIndexes.append(index)
                    }
                }

                let markers = Array(Set(markerIndexes)).sorted()
                    .map { index in
                        guard let url = citations[index - 1].safeURL else { return "" }
                        return "[[\(index)]](\(url.absoluteString))"
                    }
                    .joined(separator: " ")
                renderedBlocks.append(markers.isEmpty ? block.text : "\(block.text) \(markers)")
            }

            let answer = renderedBlocks.joined(separator: "\n\n")
            guard !citations.isEmpty else { return answer }

            let sources = citations.enumerated().compactMap { offset, citation -> String? in
                guard let url = citation.safeURL else { return nil }
                return "\(offset + 1). [\(citation.markdownTitle)](\(url.absoluteString))"
            }
            return "\(answer)\n\nSources\n\(sources.joined(separator: "\n"))"
        }

        private var textBlocks: [TextBlock] {
            content.compactMap { value in
                guard let object = value.objectValue,
                      object["type"]?.stringValue == "text",
                      let text = object["text"]?.stringValue else { return nil }
                let citations = object["citations"]?.arrayValue?.compactMap(WebCitation.init) ?? []
                return TextBlock(text: text, citations: citations)
            }
        }

        private struct TextBlock {
            let text: String
            let citations: [WebCitation]
        }

        struct WebCitation: Equatable {
            let url: String
            let title: String

            nonisolated init?(_ value: JSONValue) {
                guard let object = value.objectValue,
                      let url = object["url"]?.stringValue else { return nil }
                self.url = url
                self.title = object["title"]?.stringValue ?? url
            }

            var safeURL: URL? {
                guard let url = URL(string: url),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "https" || scheme == "http" else { return nil }
                return url
            }

            var markdownTitle: String {
                title
                    .replacingOccurrences(of: "[", with: "\\[")
                    .replacingOccurrences(of: "]", with: "\\]")
            }
        }
    }

    struct WebSearchReply {
        let text: String
        let usage: MessageResponse.Usage
        let webSearchRequests: Int
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
        let reply = try await messageDetailed(
            system: system,
            messages: [.init(role: "user", content: user)],
            model: model,
            maxTokens: maxTokens
        )
        return (reply.text, reply.usage)
    }

    /// Sends a multi-turn conversation. The caller owns and resubmits the history
    /// because the Messages API is stateless between requests.
    func message(
        system: String,
        messages: [Message],
        model: String = AnthropicClient.defaultModel,
        maxTokens: Int = 2048
    ) async throws -> (text: String, usage: MessageResponse.Usage) {
        let body = MessageRequest(
            model: model,
            maxTokens: maxTokens,
            system: system,
            messages: messages
        )

        let decoded = try await send(body)
        guard let text = decoded.firstText else {
            throw AnthropicError.emptyResponse
        }
        return (text, decoded.usage)
    }

    /// Includes the API stop reason so structured-output callers can reject or
    /// retry a response that was cut off at the token limit.
    func messageDetailed(
        system: String,
        messages: [Message],
        model: String = AnthropicClient.defaultModel,
        maxTokens: Int = 2048
    ) async throws -> (text: String, usage: MessageResponse.Usage, stopReason: String?) {
        let body = MessageRequest(
            model: model,
            maxTokens: maxTokens,
            system: system,
            messages: messages
        )
        let decoded = try await send(body)
        guard let text = decoded.firstText else {
            throw AnthropicError.emptyResponse
        }
        return (text, decoded.usage, decoded.stopReason)
    }

    /// Sends a conversation with Anthropic's server-side web search tool enabled.
    /// Claude invokes the tool only when the question needs outside information.
    func messageWithWebSearch(
        system: String,
        messages: [Message],
        model: String = AnthropicClient.defaultModel,
        maxTokens: Int = 2_048,
        maxSearches: Int = 3
    ) async throws -> WebSearchReply {
        var conversation = messages
        var responseContent: [JSONValue] = []
        var totalInputTokens = 0
        var totalOutputTokens = 0
        var totalSearchRequests = 0

        // Anthropic can pause a server-tool turn when it needs more time. Resubmit
        // the full assistant content so the search can finish without losing state.
        for _ in 0..<3 {
            let body = MessageRequest(
                model: model,
                maxTokens: maxTokens,
                system: system,
                messages: conversation,
                tools: [.webSearch(maxUses: maxSearches)]
            )
            let decoded = try await send(body)
            responseContent.append(contentsOf: decoded.content)
            totalInputTokens += decoded.usage.inputTokens
            totalOutputTokens += decoded.usage.outputTokens
            totalSearchRequests += decoded.webSearchRequestCount

            if decoded.stopReason == "pause_turn" {
                conversation.append(.init(role: "assistant", contentBlocks: decoded.content))
                continue
            }

            let combined = MessageResponse(
                id: decoded.id,
                model: decoded.model,
                content: responseContent,
                usage: .init(inputTokens: totalInputTokens, outputTokens: totalOutputTokens),
                stopReason: decoded.stopReason
            )
            let text = combined.renderedWebSearchText
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AnthropicError.emptyResponse
            }
            return WebSearchReply(
                text: text,
                usage: combined.usage,
                webSearchRequests: totalSearchRequests
            )
        }

        throw AnthropicError.serverError(
            "Web research took too many continuation steps. Please try a narrower question."
        )
    }

    private func send(_ body: MessageRequest) async throws -> MessageResponse {
        guard CloudAIConsent.isGranted else { throw CloudAIConsentError.required }
        let encodedBody = try JSONEncoder().encode(body)
        if apiKey == nil {
            let data = try await MomentusBackendClient.shared.perform(
                operation: "anthropic.messages",
                body: encodedBody
            )
            return try decode(MessageResponse.self, from: data)
        }

        var request = URLRequest(url: baseURL.appending(path: "/v1/messages"))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = encodedBody

        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)

        let decoded = try decode(MessageResponse.self, from: data)
        return decoded
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
