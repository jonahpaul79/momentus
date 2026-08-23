@preconcurrency import AVFoundation
import Foundation

/// Keeps legacy, high-bitrate recordings below the cloud Storage limit without
/// replacing or modifying the authoritative recording saved on the device.
enum CloudAudioPreparationService {
    nonisolated private static let preparationThreshold: Int64 = 45 * 1_024 * 1_024
    nonisolated private static let targetBitRate = 32_000
    nonisolated private static let targetSampleRate = 16_000

    struct PreparedAudio: Sendable {
        let url: URL
        let shouldRemove: Bool
    }

    nonisolated static func prepare(
        sourceURL: URL,
        recordingID: UUID,
        progress: (@MainActor (AudioUploadProgress) -> Void)?
    ) async throws -> PreparedAudio {
        let sourceSize = Int64(
            (try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        )
        guard sourceSize > 0 else { throw MomentusBackendError.emptyRecording }
        guard sourceSize > preparationThreshold else {
            return PreparedAudio(url: sourceURL, shouldRemove: false)
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("momentus-cloud-\(recordingID.uuidString.lowercased()).m4a")
        try? FileManager.default.removeItem(at: outputURL)
        await progress?(AudioUploadProgress(bytesSent: 0, totalBytes: sourceSize, stage: .preparing))
        print("[Cloud Audio] optimizing \(sourceSize) bytes before upload")

        do {
            try await transcode(
                sourceURL: sourceURL,
                outputURL: outputURL,
                sourceSize: sourceSize,
                progress: progress
            )
            let outputSize = Int64(
                (try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            )
            guard outputSize > 0 else { throw CloudAudioPreparationError.transcodeFailed }
            guard outputSize <= preparationThreshold else {
                throw CloudAudioPreparationError.stillTooLarge(outputSize)
            }
            print("[Cloud Audio] optimized recording to \(outputSize) bytes")
            return PreparedAudio(url: outputURL, shouldRemove: true)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    nonisolated private static func transcode(
        sourceURL: URL,
        outputURL: URL,
        sourceSize: Int64,
        progress: (@MainActor (AudioUploadProgress) -> Void)?
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0,
              let track = try await asset.loadTracks(withMediaType: .audio).first
        else { throw CloudAudioPreparationError.invalidAudio }

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: targetSampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else { throw CloudAudioPreparationError.transcodeFailed }
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let writerInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: targetSampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: targetBitRate,
            ]
        )
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else { throw CloudAudioPreparationError.transcodeFailed }
        writer.add(writerInput)

        guard reader.startReading(), writer.startWriting() else {
            throw reader.error ?? writer.error ?? CloudAudioPreparationError.transcodeFailed
        }
        writer.startSession(atSourceTime: .zero)

        do {
            while reader.status == .reading {
                try Task.checkCancellation()
                guard writerInput.isReadyForMoreMediaData else {
                    try await Task.sleep(for: .milliseconds(10))
                    continue
                }
                guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else { break }
                guard writerInput.append(sampleBuffer) else {
                    throw writer.error ?? CloudAudioPreparationError.transcodeFailed
                }
                let seconds = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
                let fraction = min(0.99, max(0, seconds / duration))
                await progress?(AudioUploadProgress(
                    bytesSent: Int64(Double(sourceSize) * fraction),
                    totalBytes: sourceSize,
                    stage: .preparing
                ))
            }
            guard reader.status == .completed else {
                throw reader.error ?? CloudAudioPreparationError.transcodeFailed
            }
            writerInput.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw writer.error ?? CloudAudioPreparationError.transcodeFailed
            }
            await progress?(AudioUploadProgress(
                bytesSent: sourceSize,
                totalBytes: sourceSize,
                stage: .preparing
            ))
        } catch {
            reader.cancelReading()
            writerInput.markAsFinished()
            writer.cancelWriting()
            throw error
        }
    }
}

enum CloudAudioPreparationError: LocalizedError {
    case invalidAudio
    case transcodeFailed
    case stillTooLarge(Int64)

    var errorDescription: String? {
        switch self {
        case .invalidAudio:
            return "The recording could not be read while preparing it for cloud upload."
        case .transcodeFailed:
            return "Momentus could not optimize this recording for cloud upload. The original audio is unchanged."
        case .stillTooLarge(let bytes):
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return "The optimized recording is still too large for cloud upload (\(size))."
        }
    }
}
