import Foundation
import Supabase

/// Authenticated transport for Momentus-owned AI services.
///
/// The client-safe anon key identifies this app and is intentionally safe to ship in the binary.
/// Provider credentials never enter the app; they live in Supabase Edge Function secrets.
actor MomentusBackendClient {
    static let shared = MomentusBackendClient()

    nonisolated static let projectURL = URL(string: "https://hbljfwhhyxppcughhulp.supabase.co")!
    nonisolated static let clientKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImhibGpmd2hoeXhwcGN1Z2hodWxwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODY5ODc5NjMsImV4cCI6MjEwMjU2Mzk2M30.AMQw2nOjOBeg3rkSv7rC7Dph_eIb2OgQZvHfne05cMw"
    nonisolated static let isConfigured = true

    private let supabase: SupabaseClient
    private let urlSession: URLSession

    private init() {
        supabase = SupabaseClient(
            supabaseURL: Self.projectURL,
            supabaseKey: Self.clientKey
        )

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 1_800
        urlSession = URLSession(configuration: configuration)
    }

    func perform(
        operation: String,
        body: Data? = nil,
        contentType: String = "application/json",
        queryItems: [URLQueryItem] = []
    ) async throws -> Data {
        let session = try await authenticatedSession()
        var components = URLComponents(
            url: Self.projectURL.appending(path: "/functions/v1/ai-gateway"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "operation", value: operation)] + queryItems

        guard let url = components.url else { throw MomentusBackendError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue(Self.clientKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("momentus-ios/1", forHTTPHeaderField: "x-client-info")

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MomentusBackendError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(BackendErrorBody.self, from: data).error)
                ?? String(data: data, encoding: .utf8)
                ?? "HTTP \(http.statusCode)"
            throw MomentusBackendError.server(status: http.statusCode, message: message)
        }
        return data
    }

    /// Upload a file without first copying the complete recording into app memory.
    func upload(operation: String, fileURL: URL, contentType: String) async throws -> Data {
        let session = try await authenticatedSession()
        var components = URLComponents(
            url: Self.projectURL.appending(path: "/functions/v1/ai-gateway"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "operation", value: operation)]

        guard let url = components.url else { throw MomentusBackendError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(Self.clientKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("momentus-ios/1", forHTTPHeaderField: "x-client-info")

        let (data, response) = try await urlSession.upload(for: request, fromFile: fileURL)
        try validate(response: response, data: data)
        return data
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw MomentusBackendError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(BackendErrorBody.self, from: data).error)
                ?? String(data: data, encoding: .utf8)
                ?? "HTTP \(http.statusCode)"
            throw MomentusBackendError.server(status: http.statusCode, message: message)
        }
    }

    private func authenticatedSession() async throws -> Session {
        do {
            return try await supabase.auth.session
        } catch {
            return try await supabase.auth.signInAnonymously()
        }
    }
}

private nonisolated struct BackendErrorBody: Decodable, Sendable {
    let error: String
}

enum MomentusBackendError: LocalizedError {
    case invalidConfiguration
    case invalidResponse
    case server(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Momentus cloud services are not configured."
        case .invalidResponse:
            return "Momentus received an invalid cloud response."
        case .server(let status, let message):
            if status == 401 { return "Your Momentus session expired. Please try again." }
            if status == 429 { return "You have reached the current usage limit. Please try again later." }
            return "Momentus cloud error: \(message)"
        }
    }
}
