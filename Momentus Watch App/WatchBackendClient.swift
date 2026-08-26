import Foundation
import Supabase

actor WatchBackendClient {
    static let shared = WatchBackendClient()

    private static let projectURL = URL(string: "https://hbljfwhhyxppcughhulp.supabase.co")!
    private static let clientKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImhibGpmd2hoeXhwcGN1Z2hodWxwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODY5ODc5NjMsImV4cCI6MjEwMjU2Mzk2M30.AMQw2nOjOBeg3rkSv7rC7Dph_eIb2OgQZvHfne05cMw"

    private let supabase = SupabaseClient(
        supabaseURL: projectURL,
        supabaseKey: clientKey
    )
    private let urlSession: URLSession

    private init() {
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
        if operation != "assemblyai.poll",
           operation != "assemblyai.delete",
           !WatchCloudAIConsent.isGranted {
            throw WatchBackendError.cloudAIConsentRequired
        }
        let session: Session
        do {
            session = try await supabase.auth.session
        } catch {
            session = try await supabase.auth.signInAnonymously()
        }

        var components = URLComponents(
            url: Self.projectURL.appending(path: "/functions/v1/ai-gateway"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "operation", value: operation)] + queryItems

        guard let url = components.url else { throw WatchBackendError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue(Self.clientKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WatchBackendError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw WatchBackendError.server(message)
        }
        return data
    }
}

enum WatchBackendError: LocalizedError {
    case invalidResponse
    case server(String)
    case cloudAIConsentRequired

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Momentus received an invalid cloud response."
        case .server(let message): return "Momentus cloud error: \(message)"
        case .cloudAIConsentRequired: return "Allow Cloud AI processing before sending this recording."
        }
    }
}
