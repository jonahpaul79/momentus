import Speech
import AVFoundation
import Foundation

final class AppleSpeechTranscriptionService: TranscriptionService {
    let providerName = "Apple On-Device"
    let isOnDevice = true

    // SFSpeechRecognizer caps file-based requests at ~60 seconds of audio.
    // We split longer files into chunks and join the results.
    private static let chunkDuration: TimeInterval = 55

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

        let recognizer = SFSpeechRecognizer(locale: Locale.current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer else {
            throw SpeechTranscriptionError.recognizerUnavailable
        }

        // isAvailable can be false immediately after init while the recognizer
        // finishes async setup. Wait up to 3 seconds before giving up.
        var waited = 0
        while !recognizer.isAvailable && waited < 6 {
            try await Task.sleep(for: .milliseconds(500))
            waited += 1
        }
        guard recognizer.isAvailable else {
            print("[Speech] recognizer still unavailable after \(waited * 500)ms — using stub")
            return stubTranscript(recordingId: recordingId)
        }

        let fileURL = AVAudioRecorderService.recordingsDirectory.appendingPathComponent(audioFileID)

        // Measure duration so we know whether to chunk
        let asset = AVURLAsset(url: fileURL)
        let duration: TimeInterval
        do {
            let cmDuration = try await asset.load(.duration)
            duration = CMTimeGetSeconds(cmDuration)
        } catch {
            print("[Speech] could not read asset duration: \(error) — attempting direct recognition")
            duration = 0
        }
        print("[Speech] audio duration: \(String(format: "%.1f", duration))s")

        if recognizer.supportsOnDeviceRecognition {
            // Use on-device model when available — no network, no 1-minute cloud limit
        }

        if duration <= Self.chunkDuration || duration == 0 {
            return try await recognizeFile(at: fileURL, recognizer: recognizer,
                                           timeOffset: 0, recordingId: recordingId)
        }

        // Split into chunks and concatenate transcripts
        print("[Speech] long audio — splitting into \(Self.chunkDuration)s chunks")
        let chunkURLs = try await exportChunks(from: fileURL, duration: duration)
        defer { chunkURLs.forEach { try? FileManager.default.removeItem(at: $0) } }

        var allSegments: [TranscriptSegment] = []
        for (i, chunkURL) in chunkURLs.enumerated() {
            let offset = Double(i) * Self.chunkDuration
            print("[Speech] chunk \(i + 1)/\(chunkURLs.count) (offset \(offset)s)")
            let chunkTranscript = try await recognizeFile(at: chunkURL, recognizer: recognizer,
                                                          timeOffset: offset, recordingId: recordingId)
            allSegments.append(contentsOf: chunkTranscript.segments)
        }

        let speaker = Speaker(id: UUID(), name: "Speaker 1", isNameInferred: true, colorHex: "#6366F1")
        let transcript = Transcript(
            id: UUID(),
            recordingId: recordingId,
            segments: allSegments,
            speakers: allSegments.isEmpty ? [] : [speaker],
            language: Locale.current.identifier,
            provider: providerName,
            createdAt: Date()
        )
        print("[Speech] done — \(transcript.segments.count) segments from \(chunkURLs.count) chunks")
        return transcript
    }

    // MARK: - Recognise a single file

    private func recognizeFile(
        at fileURL: URL,
        recognizer: SFSpeechRecognizer,
        timeOffset: TimeInterval,
        recordingId: UUID
    ) async throws -> Transcript {
        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let box = SFTaskBox()
        let sfResult = try await withThrowingTaskGroup(of: SFSpeechRecognitionResult?.self) { group in
            group.addTask {
                return try await withTaskCancellationHandler {
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
                    box.task?.cancel()
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(120))
                print("[Speech] 2-minute per-chunk timeout fired")
                return nil
            }
            let first = try await group.next()
            group.cancelAll()
            return first ?? nil
        }

        guard let result = sfResult else {
            print("[Speech] no result for chunk at offset \(timeOffset)s — using stub")
            return stubTranscript(recordingId: recordingId)
        }

        return buildTranscript(from: result, timeOffset: timeOffset, recordingId: recordingId)
    }

    // MARK: - Audio chunking

    private func exportChunks(from fileURL: URL, duration: TimeInterval) async throws -> [URL] {
        let chunkCount = Int(ceil(duration / Self.chunkDuration))
        var urls: [URL] = []

        for i in 0..<chunkCount {
            let start = Double(i) * Self.chunkDuration
            let end = min(start + Self.chunkDuration, duration)
            let chunkURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("chunk_\(i)_\(UUID().uuidString).m4a")

            let asset = AVURLAsset(url: fileURL)
            guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                throw SpeechTranscriptionError.exportFailed
            }
            exporter.timeRange = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 1000),
                end: CMTime(seconds: end, preferredTimescale: 1000)
            )
            try await exporter.export(to: chunkURL, as: .m4a)
            urls.append(chunkURL)
        }
        return urls
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

    private func buildTranscript(
        from result: SFSpeechRecognitionResult,
        timeOffset: TimeInterval,
        recordingId: UUID
    ) -> Transcript {
        let speaker = Speaker(id: UUID(), name: "Speaker 1", isNameInferred: true, colorHex: "#6366F1")
        let wordSegments = result.bestTranscription.segments
        let fullText = result.bestTranscription.formattedString

        var sentences: [String] = []
        fullText.enumerateSubstrings(in: fullText.startIndex..., options: .bySentences) { sub, _, _, _ in
            if let s = sub?.trimmingCharacters(in: .whitespaces), !s.isEmpty { sentences.append(s) }
        }
        if sentences.isEmpty && !fullText.isEmpty { sentences = [fullText] }

        let avgConf: Float = wordSegments.isEmpty ? 0.85 :
            wordSegments.map { $0.confidence > 0 ? $0.confidence : 0.85 }.reduce(0, +) / Float(wordSegments.count)
        let chunkDuration = wordSegments.last.map { $0.timestamp + $0.duration } ?? 1.0

        let segments = sentences.enumerated().map { i, sentence in
            TranscriptSegment(
                id: UUID(),
                text: sentence,
                startTime: timeOffset + Double(i) / Double(sentences.count) * chunkDuration,
                endTime: timeOffset + Double(i + 1) / Double(sentences.count) * chunkDuration,
                speakerId: speaker.id,
                confidence: avgConf
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

private final class SFTaskBox: @unchecked Sendable {
    nonisolated(unsafe) var task: SFSpeechRecognitionTask?
}

enum SpeechTranscriptionError: LocalizedError {
    case recognizerUnavailable
    case authorizationDenied
    case noSpeechDetected
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable: return "Speech recognition is not available on this device."
        case .authorizationDenied: return "Speech recognition permission was denied. Please enable it in Settings."
        case .noSpeechDetected: return "No speech was detected in the recording."
        case .exportFailed: return "Failed to split audio for transcription."
        }
    }
}
