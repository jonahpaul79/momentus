# Momentus

Dark-mode-first, Apple Watch-powered AI meeting recorder for real-world, in-person conversations. Built with SwiftUI for iOS and watchOS.

---

## Architecture

### Pattern: MVVM with Observable

- **ViewModels** use Swift's `@Observable` macro (iOS 17+). No `@Published` needed.
- **Shared state** (recordings list, theme) lives in `@Observable` classes injected via `.environment(...)`.
- **Views** receive `@Environment(ThemeManager.self)` and `@Environment(RecordingsStore.self)` — no singletons.
- **Settings** use `@AppStorage` for direct UserDefaults persistence.

### Key Objects

| Object | Role |
|---|---|
| `ThemeManager` | Observable class managing the active `AppTheme` preset |
| `RecordingsStore` | Observable class holding all `Recording` objects in memory |
| `RecordViewModel` | Drives recording timer, waveform, and the processing pipeline |
| `NotesViewModel` | Handles search + filter logic for the notes list |

### Navigation

```
ContentView (TabView)
├── Tab: Record
│   └── NavigationStack → RecordHomeView
│       ├── fullScreenCover → ActiveRecordingView
│       └── fullScreenCover → ProcessingView
├── Tab: Notes
│   └── NavigationStack → NotesListView
│       └── sheet → MeetingSummaryDetailView
│           └── sheet → TranscriptDetailView
└── Tab: Settings
    └── NavigationStack → SettingsView
```

---

## Theming System

All colors, typography, spacing, radius, shadows, and gradients are defined in theme tokens — **no hardcoded values in views**.

### Theme Types

| Type | Purpose |
|---|---|
| `AppTheme` | Root struct composing all sub-theme types |
| `ThemeColors` | All color tokens (backgrounds, surfaces, accents, text, dividers) |
| `ThemeTypography` | All font definitions (display, headline, body, label, timer) |
| `ThemeSpacing` | Spacing scale (xxs → hero) |
| `ThemeRadius` | Corner radius tokens (s → pill) |
| `ThemeShadow` | Shadow styles (card, elevated, recording glow, modal) |
| `ThemeGradients` | Pre-built gradient definitions (hero bg, recording glow, card accent) |
| `ThemeManager` | Observable class — holds `currentTheme` and persists `currentPreset` |

### Switching Themes

```swift
// Get the theme manager from environment
@Environment(ThemeManager.self) private var themeManager

// Switch preset
themeManager.currentPreset = .graphiteCrimson
```

### Adding a New Theme

1. Add a case to `ThemePreset` enum in `AppTheme.swift`
2. Add a static `AppTheme` property extension:

```swift
extension AppTheme {
    static let yourNewTheme: AppTheme = {
        let colors = ThemeColors(backgroundPrimary: ..., /* all tokens */)
        let shadows = ThemeShadow(...)
        let gradients = ThemeGradients(...)
        return AppTheme(name: "Your Theme", colors: colors, typography: .default,
                        spacing: .default, radius: .default, shadows: shadows, gradients: gradients)
    }()
}
```

3. Wire it in `ThemePreset.theme` property.

---

## Provider Architecture

Each AI capability is behind a protocol. Swap providers without touching any UI.

### Transcription

**Protocol:** `TranscriptionService`

```swift
protocol TranscriptionService {
    var providerName: String { get }
    var isOnDevice: Bool { get }
    func transcribe(audioFileID: String, recordingId: UUID) async throws -> Transcript
}
```

**Where to add providers:**

```
Momentus/Services/
├── ServiceProtocols.swift      ← protocols live here
└── Providers/
    ├── AppleSpeechTranscriptionService.swift   ← TODO: Apple SpeechAnalyzer
    ├── SonioxTranscriptionService.swift         ← TODO: Soniox REST API
    └── DeepgramTranscriptionService.swift       ← TODO: Deepgram WebSocket
```

### Adding Apple SpeechAnalyzer

```swift
// File: Services/Providers/AppleSpeechTranscriptionService.swift
import Speech

final class AppleSpeechTranscriptionService: TranscriptionService {
    let providerName = "Apple On-Device"
    let isOnDevice = true

    func transcribe(audioFileID: String, recordingId: UUID) async throws -> Transcript {
        // 1. Get audio file URL from audioFileID
        // 2. Create SFSpeechRecognizer(locale: .current)
        // 3. Use SFSpeechURLRecognitionRequest
        // 4. Enable .requiresOnDeviceRecognition = true for Private mode
        // 5. Map SFTranscriptionSegment → TranscriptSegment
        // 6. Perform speaker diarization if available
    }
}
```

### Adding Soniox

```swift
// File: Services/Providers/SonioxTranscriptionService.swift
final class SonioxTranscriptionService: TranscriptionService {
    let providerName = "Soniox"
    let isOnDevice = false
    private let apiKey: String

    // POST audio to api.soniox.com/transcribe
    // Map response to Transcript model
    // Store API key in Keychain, never UserDefaults
}
```

### Summary Services

**Protocol:** `SummaryService`

```swift
protocol SummaryService {
    var providerName: String { get }
    var isOnDevice: Bool { get }
    func summarize(transcript: Transcript, recordingId: UUID) async throws -> MeetingSummary
}
```

### Adding Apple Foundation Models

```swift
// File: Services/Providers/AppleFoundationModelsSummaryService.swift
import FoundationModels   // iOS 26+ framework

final class AppleFoundationModelsSummaryService: SummaryService {
    let providerName = "Apple Foundation Models"
    let isOnDevice = true

    func summarize(transcript: Transcript, recordingId: UUID) async throws -> MeetingSummary {
        // 1. Build structured prompt from transcript.fullText
        // 2. Use LanguageModelSession for on-device generation
        // 3. Parse structured JSON response → MeetingSummary
    }
}
```

### Adding Claude API

```swift
// File: Services/Providers/ClaudeSummaryService.swift
// ⚠️  Store API key in Keychain only — never UserDefaults or code
final class ClaudeSummaryService: SummaryService {
    let providerName = "Claude (Anthropic)"
    let isOnDevice = false

    // POST to api.anthropic.com/v1/messages
    // Use claude-sonnet-4-6 or claude-opus-4-8 for best results
    // Include structured output prompt to return JSON matching MeetingSummary
    // Consider prompt caching for repeated summarization patterns
}
```

### Adding OpenAI

```swift
// File: Services/Providers/OpenAISummaryService.swift
// ⚠️  Store API key in Keychain
final class OpenAISummaryService: SummaryService {
    let providerName = "OpenAI"
    let isOnDevice = false
    // POST to api.openai.com/v1/chat/completions with structured outputs
}
```

---

## Privacy Modes

| Mode | Transcription | Summary | Audio |
|---|---|---|---|
| **Private** | On-device (Apple Speech) | On-device (Apple FM) | Never leaves device |
| **Best Quality** | Cloud (Soniox/Deepgram) | Cloud (Claude/OpenAI) | Sent to provider, deleted after |
| **Hybrid** | On-device | Cloud (Claude/OpenAI) | Transcript sent, not raw audio |

Privacy copy used throughout the app:
- "Private Mode keeps transcription and summaries on-device when supported."
- "Best Quality sends audio/transcript to selected providers for better accuracy."
- "Raw audio can be deleted automatically after transcription."
- "No meeting content is used for training by this app."

---

## Recording Flow

```
User taps Record
    → RecordViewModel.startRecording()
    → RecordingService.startRecording(mode:source:)
    → ActiveRecordingView shown (timer + waveform + orb)

User taps Stop
    → RecordingService.stopRecording() → audioFileID
    → TranscriptionService.transcribe(audioFileID:recordingId:) → Transcript
    → SummaryService.summarize(transcript:recordingId:) → MeetingSummary
    → Recording saved to RecordingsStore
    → ProcessingView shows step-by-step progress
    → Notes tab shows new recording
```

---

## Folder Structure

```
Momentus/
├── App/
│   ├── MomentusApp.swift
│   └── ContentView.swift
├── Theme/
│   └── AppTheme.swift              ← ThemeColors, ThemeTypography, ThemeSpacing,
│                                      ThemeRadius, ThemeShadow, ThemeGradients,
│                                      AppTheme, ThemePreset, ThemeManager
├── Models/
│   └── Models.swift                ← All model types
├── Services/
│   ├── ServiceProtocols.swift      ← All service protocols + provider enums
│   ├── Mock/
│   │   └── MockServices.swift      ← MockRecordingService, MockTranscriptionService,
│   │                                  MockSummaryService, LocalStorageService,
│   │                                  MockCalendarContextService, RecordingsStore
│   └── Providers/                  ← TODO: real provider implementations
├── MockData/
│   └── MockMeetings.swift          ← Realistic sample meetings and transcripts
├── Features/
│   ├── Record/
│   │   ├── RecordViewModel.swift
│   │   ├── RecordHomeView.swift
│   │   ├── ActiveRecordingView.swift
│   │   └── ProcessingView.swift
│   ├── Notes/
│   │   ├── NotesViewModel.swift
│   │   ├── NotesListView.swift
│   │   ├── MeetingSummaryDetailView.swift
│   │   └── TranscriptDetailView.swift
│   ├── Settings/
│   │   └── SettingsView.swift
│   └── Onboarding/
│       └── OnboardingView.swift
├── Shared/
│   ├── Components/
│   │   └── WaveformView.swift      ← WaveformView, StaticWaveformView, RecordingOrb
│   └── Extensions/
│       └── ViewExtensions.swift    ← SurfaceCardModifier, ModeBadge, ConfidenceBadge,
│                                      TimeInterval formatters, HapticStyle
Momentus Watch App/
├── MomentusApp.swift
├── ContentView.swift
├── WatchHomeView.swift
├── WatchActiveRecordingView.swift
├── WatchSavedView.swift
├── WatchViewModel.swift
└── WatchTheme.swift
```

---

## What's Next (Provider Integration)

Priority order for production implementation:

1. **Apple SpeechAnalyzer** — on-device transcription, no API key needed, powers Private mode
2. **Apple Foundation Models** — on-device summarization for full offline mode (iOS 26+)
3. **AVAudioRecorder** — replace MockRecordingService with real audio capture
4. **WatchConnectivity** — wire up WCSession for Watch ↔ iPhone communication
5. **Keychain storage** — secure API key storage before adding any cloud provider
6. **Deepgram/Soniox** — cloud transcription for Best Quality mode
7. **Claude API** — cloud summarization via Anthropic SDK
8. **CloudKit** — iCloud sync for recordings across devices
9. **Live Activities** — recording state on Lock Screen
10. **Watch Complications** — recording trigger from watch face
