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
    nonisolated static let recordingAudioBucket = "recording-audio"
    nonisolated private static let tusVersion = "1.0.0"
    nonisolated private static let tusChunkSize = 6 * 1024 * 1024

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

    /// Stages a recording directly in private object storage. This deliberately
    /// bypasses the Edge Function proxy, whose request can time out while a large
    /// mobile upload is still in flight.
    func stageRecordingAudio(
        fileURL: URL,
        recordingID: UUID,
        progress: (@MainActor (AudioUploadProgress) -> Void)? = nil
    ) async throws -> URL {
        let session = try await authenticatedSession()
        let path = recordingAudioPath(userID: session.user.id.uuidString, recordingID: recordingID)
        let bucket = supabase.storage.from(Self.recordingAudioBucket)
        try await resumableUpload(
            fileURL: fileURL,
            objectPath: path,
            recordingID: recordingID,
            progress: progress
        )
        return try await bucket.createSignedURL(path: path, expiresIn: 86_400)
    }

    func deleteStagedRecordingAudio(recordingID: UUID) async {
        do {
            let session = try await authenticatedSession()
            let path = recordingAudioPath(userID: session.user.id.uuidString, recordingID: recordingID)
            _ = try await supabase.storage.from(Self.recordingAudioBucket).remove(paths: [path])
        } catch {
            // Cleanup must not turn a completed transcript into a failed meeting.
            print("[MomentusBackend] staged audio cleanup failed: \(error)")
        }
    }

    private func recordingAudioPath(userID: String, recordingID: UUID) -> String {
        "\(userID.lowercased())/\(recordingID.uuidString.lowercased()).m4a"
    }

    // MARK: - Resumable recording upload (TUS)

    private func resumableUpload(
        fileURL: URL,
        objectPath: String,
        recordingID: UUID,
        progress: (@MainActor (AudioUploadProgress) -> Void)?
    ) async throws {
        let fileSize = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard fileSize > 0 else { throw MomentusBackendError.emptyRecording }

        let checkpointKey = "momentus_tus_upload_\(recordingID.uuidString.lowercased())"
        var uploadURL = UserDefaults.standard.url(forKey: checkpointKey)
        var offset: Int64 = 0

        if let existingURL = uploadURL {
            do {
                offset = try await tusOffset(at: existingURL)
                guard offset <= Int64(fileSize) else { throw MomentusBackendError.invalidUploadOffset }
                print("[MomentusBackend] resuming staged audio at \(offset)/\(fileSize) bytes")
            } catch {
                print("[MomentusBackend] saved upload expired; creating a new one: \(error)")
                UserDefaults.standard.removeObject(forKey: checkpointKey)
                uploadURL = nil
                offset = 0
            }
        }

        if uploadURL == nil {
            uploadURL = try await createTusUpload(objectPath: objectPath, fileSize: fileSize)
            UserDefaults.standard.set(uploadURL, forKey: checkpointKey)
        }
        guard let uploadURL else { throw MomentusBackendError.invalidResponse }
        await progress?(AudioUploadProgress(bytesSent: offset, totalBytes: Int64(fileSize)))

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))

        while offset < Int64(fileSize) {
            try Task.checkCancellation()
            let remaining = Int64(fileSize) - offset
            let length = Int(min(Int64(Self.tusChunkSize), remaining))
            guard let chunk = try handle.read(upToCount: length), !chunk.isEmpty else {
                throw MomentusBackendError.invalidResponse
            }
            offset = try await patchTusUpload(url: uploadURL, offset: offset, chunk: chunk)
            await progress?(AudioUploadProgress(bytesSent: offset, totalBytes: Int64(fileSize)))
            print("[MomentusBackend] staged audio \(offset)/\(fileSize) bytes")
        }

        UserDefaults.standard.removeObject(forKey: checkpointKey)
    }

    private func createTusUpload(objectPath: String, fileSize: Int) async throws -> URL {
        let ref = Self.projectURL.host?.components(separatedBy: ".").first ?? ""
        guard let endpoint = URL(
            string: "https://\(ref).storage.supabase.co/storage/v1/upload/resumable"
        ) else { throw MomentusBackendError.invalidConfiguration }

        var lastError: Error?
        for attempt in 0..<3 {
            do {
                let session = try await authenticatedSession()
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                // Some HTTP stacks omit Content-Length for a bodyless POST. TUS
                // creation requires an explicitly empty request when creation-with-
                // upload is not being used.
                request.httpBody = Data()
                addTusAuthorization(to: &request, accessToken: session.accessToken)
                request.setValue(Self.tusVersion, forHTTPHeaderField: "Tus-Resumable")
                request.setValue(String(fileSize), forHTTPHeaderField: "Upload-Length")
                request.setValue("true", forHTTPHeaderField: "x-upsert")
                request.setValue(
                    tusMetadata([
                        "bucketName": Self.recordingAudioBucket,
                        "objectName": objectPath,
                        "contentType": "audio/mp4",
                        "cacheControl": "3600",
                    ]),
                    forHTTPHeaderField: "Upload-Metadata"
                )

                let (data, response) = try await urlSession.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw MomentusBackendError.invalidResponse
                }
                guard (200...299).contains(http.statusCode) else {
                    throw storageResponseError(http: http, data: data, context: "starting upload")
                }
                guard let location = http.value(forHTTPHeaderField: "Location"),
                      let uploadURL = URL(string: location, relativeTo: endpoint)?.absoluteURL
                else {
                    throw MomentusBackendError.storageResponse(
                        status: http.statusCode,
                        message: "The upload service did not provide a resume URL."
                    )
                }
                return uploadURL
            } catch {
                lastError = error
                guard attempt < 2, isRetryableUploadError(error) else { break }
                print("[MomentusBackend] upload creation attempt \(attempt + 1) failed: \(error.localizedDescription)")
                try await Task.sleep(for: .seconds(attempt == 0 ? 1 : 3))
            }
        }
        throw lastError ?? MomentusBackendError.invalidResponse
    }

    private func tusOffset(at uploadURL: URL) async throws -> Int64 {
        let session = try await authenticatedSession()
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "HEAD"
        addTusAuthorization(to: &request, accessToken: session.accessToken)
        request.setValue(Self.tusVersion, forHTTPHeaderField: "Tus-Resumable")
        let (data, response) = try await urlSession.data(for: request)
        return try uploadOffset(from: response, data: data, context: "resuming upload")
    }

    private func patchTusUpload(url: URL, offset: Int64, chunk: Data) async throws -> Int64 {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                let session = try await authenticatedSession()
                var request = URLRequest(url: url)
                request.httpMethod = "PATCH"
                request.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
                request.setValue(Self.tusVersion, forHTTPHeaderField: "Tus-Resumable")
                request.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
                addTusAuthorization(to: &request, accessToken: session.accessToken)
                let (data, response) = try await urlSession.upload(for: request, from: chunk)
                let nextOffset = try uploadOffset(from: response, data: data, context: "uploading audio")
                guard nextOffset > offset, nextOffset <= offset + Int64(chunk.count) else {
                    throw MomentusBackendError.invalidUploadOffset
                }
                return nextOffset
            } catch {
                lastError = error
                // The server may have committed the chunk even if the response was
                // lost. Trust its HEAD offset before retrying the same bytes.
                if let serverOffset = try? await tusOffset(at: url), serverOffset > offset {
                    return serverOffset
                }
                guard attempt < 2 else { break }
                try await Task.sleep(for: .seconds(attempt == 0 ? 1 : 3))
            }
        }
        throw lastError ?? MomentusBackendError.invalidResponse
    }

    private func uploadOffset(from response: URLResponse, data: Data, context: String) throws -> Int64 {
        guard let http = response as? HTTPURLResponse else {
            throw MomentusBackendError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw storageResponseError(http: http, data: data, context: context)
        }
        guard let rawOffset = http.value(forHTTPHeaderField: "Upload-Offset"),
              let offset = Int64(rawOffset)
        else {
            throw MomentusBackendError.storageResponse(
                status: http.statusCode,
                message: "The upload service did not return a valid resume position."
            )
        }
        return offset
    }

    private func storageResponseError(
        http: HTTPURLResponse,
        data: Data,
        context: String
    ) -> MomentusBackendError {
        let rawMessage = (try? JSONDecoder().decode(BackendErrorBody.self, from: data).error)
            ?? String(data: data, encoding: .utf8)
            ?? "HTTP \(http.statusCode)"
        let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        print("[MomentusBackend] Storage \(context) failed — HTTP \(http.statusCode): \(message)")
        return .storageResponse(
            status: http.statusCode,
            message: message.isEmpty ? "HTTP \(http.statusCode)" : message
        )
    }

    private func isRetryableUploadError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed]
                .contains(urlError.code)
        }
        if let backendError = error as? MomentusBackendError,
           case .storageResponse(let status, _) = backendError {
            return status == 408 || status == 425 || status == 429 || (500...599).contains(status)
        }
        return false
    }

    private func addTusAuthorization(to request: inout URLRequest, accessToken: String) {
        request.setValue(Self.clientKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("momentus-ios/1", forHTTPHeaderField: "x-client-info")
    }

    private func tusMetadata(_ values: [String: String]) -> String {
        values.sorted(by: { $0.key < $1.key }).map { key, value in
            "\(key) \(Data(value.utf8).base64EncodedString())"
        }.joined(separator: ",")
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
    case invalidUploadOffset
    case emptyRecording
    case storageResponse(status: Int, message: String)
    case server(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Momentus cloud services are not configured."
        case .invalidResponse:
            return "Momentus received an invalid cloud response."
        case .invalidUploadOffset:
            return "Momentus could not resume the recording upload. Please try again."
        case .emptyRecording:
            return "The recording audio file is empty."
        case .storageResponse(let status, let message):
            if status == 401 { return "Your Momentus session expired before the upload started. Please retry." }
            if status == 403 { return "Momentus Storage refused this recording upload. Please retry or contact support." }
            if status == 404 { return "Momentus recording storage is unavailable. Please contact support." }
            if status == 409 { return "Another upload is already using this recording. Wait a moment and retry." }
            if status == 413 { return "This recording is larger than the current cloud upload limit." }
            if status == 429 { return "Momentus Storage is busy. Wait a moment and retry." }
            return "Momentus Storage returned HTTP \(status): \(message)"
        case .server(let status, let message):
            if status == 401 { return "Your Momentus session expired. Please try again." }
            if status == 429 { return "You have reached the current usage limit. Please try again later." }
            return "Momentus cloud error: \(message)"
        }
    }
}
