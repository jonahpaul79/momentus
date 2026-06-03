import Foundation

/// Builds protocol-typed service instances based on recording mode and available API keys.
///
/// This is the single wiring point. All views and view models depend only on
/// TranscriptionService and SummaryService protocols — never on concrete types.
///
/// **Best Quality summary provider priority (key-driven):**
///   1. Claude Sonnet — if Anthropic key is present (highest quality)
///   2. AssemblyAI LeMUR — if AssemblyAI key is present (good quality, uses same transcript ID)
///   3. Apple Foundation Models — on-device fallback (no cloud key required)
///
/// **Fallback chain:**
///   ClaudeSummaryService → FallbackSummaryService → AssemblyAISummaryService or Apple
///   If Claude fails at runtime, AssemblyAI (or Apple) is tried automatically with a note.
///
/// To add a new provider:
///   1. Implement TranscriptionService or SummaryService
///   2. Add its Keychain key to KeychainService.swift
///   3. Insert it into the appropriate switch case below
enum ServiceFactory {

    // MARK: - Transcription

    static func makeTranscriptionService(for mode: RecordingMode) -> any TranscriptionService {
        switch mode {
        case .bestQuality:
            if let key = KeychainService.retrieve(.assemblyAIAPIKey), !key.isEmpty {
                print("[ServiceFactory] Best Quality → AssemblyAITranscriptionService")
                return AssemblyAITranscriptionService(apiKey: key)
            }
            print("[ServiceFactory] Best Quality — no AssemblyAI key, falling back to Apple on-device")
            return AppleSpeechTranscriptionService()

        case .onDevice, .hybrid:
            return WhisperKitTranscriptionService()
        }
    }

    // MARK: - Summary

    static func makeSummaryService(for mode: RecordingMode) -> any SummaryService {
        switch mode {
        case .bestQuality:
            let claudeKey     = KeychainService.retrieve(.anthropicAPIKey) ?? ""
            let assemblyAIKey = KeychainService.retrieve(.assemblyAIAPIKey) ?? ""

            // Claude is the preferred summary provider. Use it as primary when a key exists,
            // with AssemblyAI LeMUR (or Apple) as fallback when Claude is missing or fails.
            if !claudeKey.isEmpty {
                let claude = ClaudeSummaryService(apiKey: claudeKey)
                let apple  = AppleFoundationModelsSummaryService()

                if !assemblyAIKey.isEmpty {
                    // Claude → AssemblyAI LeMUR → Apple on-device (guaranteed last resort)
                    print("[ServiceFactory] Best Quality → Claude → AssemblyAI LeMUR → Apple")
                    return FallbackSummaryService(
                        primary: claude,
                        fallback: FallbackSummaryService(
                            primary: AssemblyAISummaryService(apiKey: assemblyAIKey),
                            fallback: apple
                        )
                    )
                } else {
                    // Claude → Apple on-device
                    print("[ServiceFactory] Best Quality → Claude → Apple")
                    return FallbackSummaryService(primary: claude, fallback: apple)
                }
            }

            // No Claude key — try AssemblyAI LeMUR directly
            if !assemblyAIKey.isEmpty {
                print("[ServiceFactory] Best Quality — no Claude key → AssemblyAI LeMUR")
                return AssemblyAISummaryService(apiKey: assemblyAIKey)
            }

            // No cloud keys at all
            print("[ServiceFactory] Best Quality — no cloud keys → Apple Foundation Models")
            return AppleFoundationModelsSummaryService()

        case .onDevice, .hybrid:
            return AppleFoundationModelsSummaryService()
        }
    }

    // MARK: - Key Status

    /// True if Best Quality transcription is available (requires AssemblyAI key).
    static func isTranscriptionConfigured(for mode: RecordingMode) -> Bool {
        guard mode == .bestQuality else { return true }
        let key = KeychainService.retrieve(.assemblyAIAPIKey) ?? ""
        return !key.isEmpty
    }

    /// True if any cloud summary provider is configured for the given mode.
    static func isSummaryConfigured(for mode: RecordingMode) -> Bool {
        guard mode == .bestQuality else { return true }
        let claude     = KeychainService.retrieve(.anthropicAPIKey) ?? ""
        let assemblyAI = KeychainService.retrieve(.assemblyAIAPIKey) ?? ""
        return !claude.isEmpty || !assemblyAI.isEmpty
    }

    /// Convenience: true when ALL required keys for the mode are present.
    /// (Drives the missing-key warning in RecordHomeView.)
    static func isConfigured(for mode: RecordingMode) -> Bool {
        isTranscriptionConfigured(for: mode)
    }

    /// Name of the summary provider that will be used for the given mode, based on current keys.
    static func summaryProviderName(for mode: RecordingMode) -> String {
        guard mode == .bestQuality else { return "Apple Foundation Models" }
        let claudeKey     = KeychainService.retrieve(.anthropicAPIKey) ?? ""
        let assemblyAIKey = KeychainService.retrieve(.assemblyAIAPIKey) ?? ""
        if !claudeKey.isEmpty     { return "Claude Sonnet (\(AnthropicClient.defaultModel))" }
        if !assemblyAIKey.isEmpty { return "AssemblyAI LeMUR" }
        return "Apple Foundation Models"
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
