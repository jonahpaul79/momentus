import Foundation

/// Builds protocol-typed service instances based on recording mode.
///
/// This is the single wiring point. All views and view models depend only on
/// TranscriptionService and SummaryService protocols — never on concrete types.
///
/// Quality modes use Momentus Cloud. Provider credentials stay in backend secrets.
///
/// **Fallback chain:**
///   ClaudeSummaryService → FallbackSummaryService → AssemblyAISummaryService or Apple
///   If Claude fails at runtime, AssemblyAI (or Apple) is tried automatically with a note.
///
/// To add a new provider:
///   1. Implement TranscriptionService or SummaryService
///   2. Insert it into the appropriate switch case below
enum ServiceFactory {

    // MARK: - Transcript Chat

    static func makeTranscriptChatService(for mode: TranscriptChatMode) throws -> any TranscriptChatService {
        switch mode {
        case .onDevice:
            return AppleFoundationModelsTranscriptChatService()
        case .bestQuality:
            return ClaudeTranscriptChatService()
        }
    }

    static var isAnthropicChatConfigured: Bool {
        MomentusBackendClient.isConfigured
    }

    // MARK: - Transcription

    static func makeTranscriptionService(for mode: RecordingMode) -> any TranscriptionService {
        switch mode {
        case .bestQuality:
            print("[ServiceFactory] Best Quality → Momentus Cloud (AssemblyAI)")
            return AssemblyAITranscriptionService()

        case .onDevice, .hybrid:
            return WhisperKitTranscriptionService()
        }
    }

    // MARK: - Summary

    static func makeSummaryService(for mode: RecordingMode) -> any SummaryService {
        switch mode {
        case .bestQuality, .hybrid:
            return makeCloudCapableSummaryService(for: mode)
        case .onDevice:
            return AppleFoundationModelsSummaryService()
        }
    }

    private static func makeCloudCapableSummaryService(for mode: RecordingMode) -> any SummaryService {
        print("[ServiceFactory] \(mode.displayName) → Momentus Cloud (Claude → AssemblyAI LeMUR → Apple)")
        return FallbackSummaryService(
            primary: ClaudeSummaryService(),
            fallback: FallbackSummaryService(
                primary: AssemblyAISummaryService(),
                fallback: AppleFoundationModelsSummaryService()
            )
        )
    }

    // MARK: - Key Status

    /// True if Best Quality transcription can use Momentus Cloud.
    static func isTranscriptionConfigured(for mode: RecordingMode) -> Bool {
        guard mode == .bestQuality else { return true }
        return MomentusBackendClient.isConfigured
    }

    /// True if any cloud summary provider is configured for the given mode.
    static func isSummaryConfigured(for mode: RecordingMode) -> Bool {
        guard mode == .bestQuality || mode == .hybrid else { return true }
        return MomentusBackendClient.isConfigured
    }

    /// Convenience used by recording UI availability checks.
    static func isConfigured(for mode: RecordingMode) -> Bool {
        isTranscriptionConfigured(for: mode)
    }

    /// Name of the summary provider that will be used for the given mode.
    static func summaryProviderName(for mode: RecordingMode) -> String {
        guard mode == .bestQuality || mode == .hybrid else { return "Apple Foundation Models" }
        return "Claude Sonnet (Momentus Cloud)"
    }
}

// MARK: - Fallback Summary Service

/// Wraps a primary and fallback SummaryService.
/// If the primary throws, the fallback is tried and a note is added to the result.
/// The RecordViewModel and all views stay unaware of which provider actually ran.
private final class FallbackSummaryService: SummaryService {
    let providerName: String
    let isOnDevice = false

    private let primary: any SummaryService
    private let fallback: any SummaryService

    init(primary: any SummaryService, fallback: any SummaryService) {
        self.primary = primary
        self.fallback = fallback
        self.providerName = primary.providerName
    }

    func summarize(transcript: Transcript, recordingId: UUID) async throws -> MeetingSummary {
        do {
            return try await primary.summarize(transcript: transcript, recordingId: recordingId)
        } catch {
            print("[FallbackSummaryService] \(primary.providerName) failed: \(error.localizedDescription)")
            print("[FallbackSummaryService] retrying with \(fallback.providerName)")
            var result = try await fallback.summarize(transcript: transcript, recordingId: recordingId)
            let note = insufficientCreditsNote(for: error, actualProvider: result.provider)
                ?? "Note: Summary generated with \(result.provider). \(primary.providerName) was unavailable."
            result.confidenceNotes.insert(note, at: 0)
            return result
        }
    }

    private func insufficientCreditsNote(for error: Error, actualProvider: String) -> String? {
        guard case AnthropicError.insufficientCredits = error else { return nil }
        return "action:addCredits:Claude credit balance is too low — final notes used \(actualProvider)."
    }
}
