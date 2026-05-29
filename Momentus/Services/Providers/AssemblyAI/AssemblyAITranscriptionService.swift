import Foundation

final class AssemblyAITranscriptionService: TranscriptionService {
    let providerName = "AssemblyAI"
    let isOnDevice = false

    private let client: AssemblyAIClient

    init(apiKey: String) {
        self.client = AssemblyAIClient(apiKey: apiKey)
    }

    func transcribe(audioFileID: String, recordingId: UUID) async throws -> Transcript {
        let fileURL = AVAudioRecorderService.recordingsDirectory.appendingPathComponent(audioFileID)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AssemblyAIError.uploadFailed("Audio file not found on device: \(audioFileID)")
        }

        print("[AssemblyAI] uploading \(audioFileID) (\(fileSizeDescription(at: fileURL)))")
        let uploadURL = try await client.upload(fileURL: fileURL)

        print("[AssemblyAI] creating transcript job")
        let transcriptID = try await client.createTranscript(uploadURL: uploadURL)

        print("[AssemblyAI] polling transcript \(transcriptID)")
        let response = try await client.pollTranscript(id: transcriptID)

        guard let text = response.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AssemblyAIError.noSpeechDetected
        }

        let utteranceCount = response.utterances?.count ?? 0
        print("[AssemblyAI] transcript complete — \(utteranceCount) utterances, \(text.count) chars")
        return buildTranscript(from: response, transcriptID: transcriptID, recordingId: recordingId)
    }

    // MARK: - Mapping

    private func buildTranscript(
        from response: AssemblyAITranscriptResponse,
        transcriptID: String,
        recordingId: UUID
    ) -> Transcript {
        let utterances = response.utterances ?? []
        let speakerMap = buildSpeakerMap(from: utterances)

        let segments: [TranscriptSegment]
        if utterances.isEmpty, let fullText = response.text {
            // No speaker-labeled utterances — create a single segment from the flat text
            let unknownSpeaker = speakerMap["A"] ?? Speaker.unknown
            segments = [
                TranscriptSegment(
                    id: UUID(),
                    text: fullText,
                    startTime: 0,
                    endTime: response.audioDuration ?? 0,
                    speakerId: unknownSpeaker.id,
                    confidence: Float(response.confidence ?? 0.85)
                )
            ]
        } else {
            segments = utterances.map { utterance in
                TranscriptSegment(
                    id: UUID(),
                    text: utterance.text,
                    startTime: utterance.startSeconds,
                    endTime: utterance.endSeconds,
                    speakerId: speakerMap[utterance.speaker]?.id,
                    confidence: Float(utterance.confidence)
                )
            }
        }

        return Transcript(
            id: UUID(),
            recordingId: recordingId,
            segments: segments,
            speakers: Array(speakerMap.values),
            language: response.languageCode ?? "en",
            provider: providerName,
            providerData: ["assemblyai_transcript_id": transcriptID],
            createdAt: Date()
        )
    }

    // Speaker labels from AssemblyAI are single letters: "A", "B", "C", etc.
    private func buildSpeakerMap(from utterances: [AssemblyAIUtterance]) -> [String: Speaker] {
        let colors = ["#6366F1", "#EC4899", "#10B981", "#F59E0B", "#3B82F6", "#8B5CF6", "#EF4444"]
        var map: [String: Speaker] = [:]
        var colorIndex = 0
        for utterance in utterances {
            guard map[utterance.speaker] == nil else { continue }
            map[utterance.speaker] = Speaker(
                id: UUID(),
                name: "Speaker \(utterance.speaker)",
                isNameInferred: false,
                colorHex: colors[colorIndex % colors.count]
            )
            colorIndex += 1
        }
        return map
    }

    private func fileSizeDescription(at url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.1f MB", mb)
    }
}
