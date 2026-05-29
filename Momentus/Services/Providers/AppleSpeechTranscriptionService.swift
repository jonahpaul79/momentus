import Speech
import Foundation

final class AppleSpeechTranscriptionService: TranscriptionService {
    let providerName = "Apple On-Device"
    let isOnDevice = true

    private static let useFallback: Bool = {
        let isSimulator = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil
        let isMac = ProcessInfo.processInfo.isiOSAppOnMac
        let result = isSimulator || isMac
        print("[Speech] useFallback=\(result) (isSimulator=\(isSimulator), isMac=\(isMac))")
        return result
    }()

    func transcribe(audioFileID: String, recordingId: UUID) async throws -> Transcript {
        if Self.useFallback {
            print("[Speech] fallback path — returning stub transcript")
            return stubTranscript(recordingId: recordingId)
        }

        print("[Speech] real path — starting SFSpeechRecognizer")

        let authStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard authStatus == .authorized else {
            throw SpeechTranscriptionError.authorizationDenied
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale.current),
              recognizer.isAvailable else {
            print("[Speech] recognizer unavailable — using stub")
            return stubTranscript(recordingId: recordingId)
        }

        let fileURL = AVAudioRecorderService.recordingsDirectory.appendingPathComponent(audioFileID)
        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true

        // Box lets the @unchecked Sendable onCancel closure reach the SF task.
        // All real access is on MainActor so the unsafety is nominal.
        let box = SFTaskBox()

        do {
            let sfResult = try await withThrowingTaskGroup(of: SFSpeechRecognitionResult?.self) { group in
                group.addTask {
                    return try await withTaskCancellationHandler {
                        // When this task is cancelled (timeout branch wins),
                        // onCancel calls sfTask.cancel() which forces the
                        // result handler to fire and resumes the continuation.
                        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<SFSpeechRecognitionResult?, Error>) in
                            var done = false
                            box.task = recognizer.recognitionTask(with: request) { result, error in
                                guard !done else { return }
                                done = true
                                if let error { cont.resume(throwing: error) }
                                else if let result, result.isFinal { cont.resume(returning: result) }
                                else { cont.resume(returning: nil) }
                            }
                        }
                    } onCancel: {
                        print("[Speech] task cancelled — forcing SF task cancel")
                        box.task?.cancel()
                    }
                }

                group.addTask {
                    try await Task.sleep(for: .seconds(15))
                    print("[Speech] 15s timeout fired")
                    return nil
                }

                let first = try await group.next()
                group.cancelAll()
                return first ?? nil
            }

            guard let result = sfResult else {
                print("[Speech] no result after timeout — using stub")
                return stubTranscript(recordingId: recordingId)
            }

            let transcript = buildTranscript(from: result, recordingId: recordingId)
            print("[Speech] done — \(transcript.segments.count) segments, \(transcript.fullText.count) chars")
            return transcript

        } catch {
            print("[Speech] error: \(error) — using stub")
            return stubTranscript(recordingId: recordingId)
        }
    }

    // MARK: - Helpers

    private func stubTranscript(recordingId: UUID) -> Transcript {
        Transcript(
            id: UUID(),
            recordingId: recordingId,
            segments: [
                TranscriptSegment(
                    id: UUID(),
                    text: "[Transcription unavailable — deploy to device with speech recognition enabled]",
                    startTime: 0,
                    endTime: 1,
                    speakerId: nil,
                    confidence: 1.0
                )
            ],
            speakers: [],
            language: "en-US",
            provider: "\(providerName) (Unavailable)",
            createdAt: Date()
        )
    }

    private func buildTranscript(from result: SFSpeechRecognitionResult, recordingId: UUID) -> Transcript {
        let speaker = Speaker(id: UUID(), name: "Speaker 1", isNameInferred: true, colorHex: "#6366F1")
        let wordSegments = result.bestTranscription.segments
        let fullText = result.bestTranscription.formattedString

        var sentences: [String] = []
        fullText.enumerateSubstrings(in: fullText.startIndex..., options: .bySentences) { sub, _, _, _ in
            if let s = sub?.trimmingCharacters(in: .whitespaces), !s.isEmpty {
                sentences.append(s)
            }
        }
        if sentences.isEmpty && !fullText.isEmpty { sentences = [fullText] }

        let avgConfidence: Float = wordSegments.isEmpty ? 0.85 : {
            wordSegments.map { $0.confidence > 0 ? $0.confidence : 0.85 }.reduce(0, +) / Float(wordSegments.count)
        }()
        let totalDuration = wordSegments.last.map { $0.timestamp + $0.duration } ?? 1.0

        let segments = sentences.enumerated().map { i, sentence in
            TranscriptSegment(
                id: UUID(),
                text: sentence,
                startTime: Double(i) / Double(sentences.count) * totalDuration,
                endTime: Double(i + 1) / Double(sentences.count) * totalDuration,
                speakerId: speaker.id,
                confidence: avgConfidence
            )
        }

        return Transcript(
            id: UUID(),
            recordingId: recordingId,
            segments: segments,
            speakers: sentences.isEmpty ? [] : [speaker],
            language: Locale.current.identifier,
            provider: providerName,
            createdAt: Date()
        )
    }
}

// Holds an SFSpeechRecognitionTask reference so the @unchecked Sendable
// onCancel closure can cancel it. Access is always on MainActor.
private final class SFTaskBox: @unchecked Sendable {
    nonisolated(unsafe) var task: SFSpeechRecognitionTask?
}

enum SpeechTranscriptionError: LocalizedError {
    case recognizerUnavailable
    case authorizationDenied
    case noSpeechDetected

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable: return "Speech recognition is not available on this device."
        case .authorizationDenied: return "Speech recognition permission was denied. Please enable it in Settings."
        case .noSpeechDetected: return "No speech was detected in the recording."
        }
    }
}
