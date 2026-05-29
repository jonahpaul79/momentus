import Foundation

// MARK: - Recording Service

/// Abstracts audio capture hardware. The active recording session is a singleton per
/// `RecordViewModel` instance — only one recording can be active at a time.
///
/// Production implementation: wrap `AVAudioSession` + `AVAudioRecorder`.
/// Returns a `fileID` string (not a `URL`) so the storage layer controls paths.
///
/// TODO: implement `AVAudioRecorderService` in `Services/Providers/`
protocol RecordingService {
    /// Begin capture. Returns a stable ID for this recording session.
    func startRecording(mode: RecordingMode, source: MicSource) async throws -> UUID
    /// Stop capture and flush to disk. Returns the `audioFileID` used by `TranscriptionService`.
    func stopRecording() async throws -> String
    func pauseRecording() async throws
    func resumeRecording() async throws
    /// Instantaneous level in 0…1 for waveform animation. Called at ~80ms intervals on main actor.
    func getCurrentLevel() -> Float
    var isRecording: Bool { get }
}

// MARK: - Transcription Service

/// Converts audio to a `Transcript` with speaker-labeled segments and confidence scores.
///
/// **Private mode** → `AppleSpeechTranscriptionService` (on-device, no data leaves device).
/// **Best Quality / Hybrid** → `SonioxTranscriptionService` or `DeepgramTranscriptionService`.
///
/// The active provider is injected into `RecordViewModel.init`. To swap providers, change
/// the default in `RecordViewModel.init(transcriptionService:)` or build a routing wrapper
/// that reads `SettingsStore.transcriptionProvider`.
///
/// TODO: implement providers in `Services/Providers/`
/// - `AppleSpeechTranscriptionService` — `SFSpeechRecognizer` + `requiresOnDeviceRecognition`
/// - `SonioxTranscriptionService` — REST, no training, zero retention
/// - `DeepgramTranscriptionService` — WebSocket streaming or batch REST
protocol TranscriptionService {
    var providerName: String { get }
    /// `true` means audio never leaves the device — required for `.onDevice` privacy mode.
    var isOnDevice: Bool { get }
    func transcribe(audioFileID: String, recordingId: UUID) async throws -> Transcript
}

// MARK: - Summary Service

/// Generates a structured `MeetingSummary` from a `Transcript`.
///
/// **Private mode** → `AppleFoundationModelsSummaryService` (iOS 26+, on-device).
/// **Best Quality / Hybrid** → `ClaudeSummaryService` or `OpenAISummaryService`.
///
/// The prompt must ask the model to return JSON that maps to `MeetingSummary` fields:
/// executiveSummary, decisions[], actionItems[], openQuestions[], risks[], followUpDraft.
/// Structured output / tool use is strongly preferred over free-text parsing.
///
/// ⚠️  API keys must be stored in Keychain before wiring up cloud providers.
///
/// TODO: implement providers in `Services/Providers/`
/// - `AppleFoundationModelsSummaryService` — `LanguageModelSession` (iOS 26+, FoundationModels)
/// - `ClaudeSummaryService` — `api.anthropic.com/v1/messages`, use structured tool output
/// - `OpenAISummaryService` — `api.openai.com/v1/chat/completions`, structured outputs
protocol SummaryService {
    var providerName: String { get }
    var isOnDevice: Bool { get }
    func summarize(transcript: Transcript, recordingId: UUID) async throws -> MeetingSummary
}

// MARK: - Storage Service

/// Persists `Recording` values including nested `Transcript` and `MeetingSummary`.
///
/// Current implementation (`LocalStorageService`): `JSONEncoder` → `UserDefaults`.
/// This is fine for MVP but will hit limits at scale. Migration path:
/// 1. Replace with SQLite / GRDB for local storage
/// 2. Add a CloudKit-backed implementation for iCloud sync
///
/// `deleteAudioFile` is separate from `deleteRecording` because audio can be purged
/// by the retention policy while keeping the transcript and summary indefinitely.
///
/// TODO: replace `LocalStorageService` with CloudKit when iCloud sync is enabled
protocol StorageService {
    func saveRecording(_ recording: Recording) async throws
    func loadRecordings() async throws -> [Recording]
    func deleteRecording(id: UUID) async throws
    func updateRecording(_ recording: Recording) async throws
    /// Deletes the raw audio file only — transcript and summary are preserved.
    func deleteAudioFile(fileID: String) async throws
}

// MARK: - Calendar Context Service

/// Reads the user's calendar to suggest a meeting title when recording starts.
/// Entirely optional — the UI degrades gracefully if access is denied.
///
/// TODO: implement `EventKitCalendarService` using `EKEventStore`.
/// Call `requestAccess()` during onboarding. Gate all reads behind the granted state.
protocol CalendarContextService {
    /// Meetings that have already started and haven't ended.
    func getCurrentMeetings() async -> [CalendarMeeting]
    /// Meetings starting within the next 5 minutes.
    func getUpcomingMeetings() async -> [CalendarMeeting]
    func requestAccess() async -> Bool
}

// MARK: - Provider Configuration

/// Carries user-chosen provider selections. Not currently stored — selections live in
/// `@AppStorage` in `SettingsView` and are read when building service instances.
struct ProviderConfig {
    var transcriptionProvider: TranscriptionProvider
    var summaryProvider: SummaryProvider
    /// Keyed by provider `rawValue`. Values must come from Keychain, never UserDefaults.
    var apiKeys: [String: String]
}

enum TranscriptionProvider: String, CaseIterable, Identifiable, Codable {
    case appleOnDevice
    case soniox
    case deepgram

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleOnDevice: return "Apple On-Device"
        case .soniox: return "Soniox"
        case .deepgram: return "Deepgram"
        }
    }

    var isOnDevice: Bool { self == .appleOnDevice }

    var privacyLabels: [String] {
        switch self {
        case .appleOnDevice: return ["On-device", "No data sent"]
        case .soniox: return ["No training", "Zero retention"]
        case .deepgram: return ["Metadata retained"]
        }
    }

    var requiresApiKey: Bool { !isOnDevice }
}

enum SummaryProvider: String, CaseIterable, Identifiable, Codable {
    case appleFoundationModels
    case claude
    case openAI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleFoundationModels: return "Apple Foundation Models"
        case .claude: return "Claude (Anthropic)"
        case .openAI: return "OpenAI"
        }
    }

    var isOnDevice: Bool { self == .appleFoundationModels }

    var privacyLabels: [String] {
        switch self {
        case .appleFoundationModels: return ["On-device", "No data sent"]
        case .claude: return ["No training", "Zero retention"]
        case .openAI: return ["Metadata retained"]
        }
    }

    var requiresApiKey: Bool { !isOnDevice }
}

enum AudioRetentionPolicy: String, CaseIterable, Identifiable, Codable {
    case deleteAfterTranscript
    case keepSevenDays
    case keepThirtyDays
    case keepForever

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .deleteAfterTranscript: return "Delete after transcript"
        case .keepSevenDays: return "Keep 7 days"
        case .keepThirtyDays: return "Keep 30 days"
        case .keepForever: return "Keep forever"
        }
    }
}
