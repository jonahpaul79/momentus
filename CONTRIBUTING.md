# Contributing to Momentus

## Setup

1. Open `Momentus.xcodeproj` in Xcode 26+
2. Select the **Momentus** scheme and any iPhone simulator
3. Build and run — no API keys or external services needed (all providers are mocked)

> **New files:** Any `.swift` file you create inside `Momentus/` or `Momentus Watch App/` is automatically included in the build. You do not need to add files to `project.pbxproj`.

---

## Project layout

```
Momentus/
  Theme/          — design system (AppTheme, ThemeManager, all token structs)
  Models/         — all value types (Recording, Transcript, MeetingSummary, …)
  Services/       — protocols for all AI/audio capabilities
    Mock/         — mock implementations used until real providers are wired
    Providers/    — (create this) real provider implementations go here
  MockData/       — realistic sample recordings for development
  Features/
    Record/       — record home, active recording, processing screens
    Notes/        — notes list, summary detail, transcript detail
    Settings/     — settings screen
    Onboarding/   — first-run flow
  Shared/
    Components/   — WaveformView, RecordingOrb, etc.
    Extensions/   — ViewExtensions (surfaceCard, ModeBadge, haptics, formatters)
Momentus Watch App/
  WatchTheme.swift       — lightweight color tokens for watchOS
  WatchViewModel.swift   — recording state for the watch, WatchConnectivity stubs
  Watch*View.swift       — three watch screens
```

---

## Design system

All visual values come from the active `AppTheme`. Never hardcode colors, spacing, or radius.

```swift
@Environment(ThemeManager.self) private var themeManager

var body: some View {
    let t = themeManager.currentTheme
    Text("Hello")
        .font(t.typography.headlineMedium)
        .foregroundStyle(t.colors.textPrimary)
        .padding(t.spacing.l)
}
```

Common token tiers:
- **Backgrounds:** `backgroundPrimary` → `backgroundSecondary`
- **Surfaces (cards):** `surfacePrimary` → `surfaceSecondary` → `surfaceTertiary`
- **Accents:** `accentPrimary` (brand), `accentRecording` (live recording only), `accentSuccess/Warning/Error`
- **Text:** `textPrimary` → `textSecondary` → `textTertiary`

Reusable card style:
```swift
YourContent()
    .padding(t.spacing.l)
    .surfaceCard()              // background + clip + border + shadow
    .environment(themeManager)  // required — surfaceCard reads ThemeManager from env
```

---

## Adding a real AI provider

All AI providers are behind protocols in `Services/ServiceProtocols.swift`. Create implementations in `Services/Providers/`.

### Transcription

Conform to `TranscriptionService`:

```swift
// Services/Providers/AppleSpeechTranscriptionService.swift
import Speech

final class AppleSpeechTranscriptionService: TranscriptionService {
    let providerName = "Apple On-Device"
    let isOnDevice = true

    func transcribe(audioFileID: String, recordingId: UUID) async throws -> Transcript {
        // 1. Resolve audio file URL from audioFileID
        // 2. SFSpeechRecognizer(locale: .current)
        // 3. SFSpeechURLRecognitionRequest — set requiresOnDeviceRecognition = true
        // 4. Map SFTranscriptionSegment → TranscriptSegment with confidence scores
    }
}
```

Then in `RecordViewModel.init(...)`, replace `MockTranscriptionService()` with your impl.

### Summarization

Conform to `SummaryService`:

```swift
// Services/Providers/ClaudeSummaryService.swift
// ⚠️ API key must come from Keychain — never UserDefaults or source code

final class ClaudeSummaryService: SummaryService {
    let providerName = "Claude"
    let isOnDevice = false

    func summarize(transcript: Transcript, recordingId: UUID) async throws -> MeetingSummary {
        // POST to api.anthropic.com/v1/messages
        // Use tool use / structured output to return JSON matching MeetingSummary fields
    }
}
```

### API key storage

Use `Security.framework` Keychain APIs directly or a thin wrapper. Never `UserDefaults`.

---

## Common patterns

**Async actions from buttons:**
```swift
Button { Task { await vm.someAction() } } label: { ... }
```

**Passing ViewModel to child views that need `@Binding`:**
```swift
// Parent (holds the vm as @State)
ChildView(vm: vm)

// Child
struct ChildView: View {
    @Bindable var vm: RecordViewModel  // @Bindable requires @Observable
}
```

**Navigating to a sheet from inside a list:**
```swift
.sheet(item: $selectedRecording) { recording in
    DetailView(recording: recording)
        .environment(themeManager)  // environment doesn't auto-propagate through sheets
        .environment(store)
}
```

**Haptics:** Use `HapticStyle.medium.trigger()` etc. (defined in `Shared/Extensions/ViewExtensions.swift`). Don't call `UIImpactFeedbackGenerator` directly.

---

## Conventions

- **Swift 6 / `@Observable`:** All ViewModels use `@Observable`, not `ObservableObject`. No `@Published`, no `@StateObject`.
- **No singletons.** Services are passed via `init` parameters. `ThemeManager` and `RecordingsStore` are env values injected from `ContentView`.
- **No presentation state in ViewModels.** Sheet booleans and navigation paths live in Views.
- **Braces on same line.** Follow existing file style.
- **Preview providers on every screen.** Wrap with `.environment(ThemeManager())` and `.preferredColorScheme(.dark)`.

---

## Running on device

1. Open project settings → Signing → select your personal team for both **Momentus** and **Momentus Watch App** targets
2. On iOS, microphone permission is requested during onboarding (or you can skip and grant it later in Settings)
3. Watch app requires pairing with a physical Apple Watch or Watch simulator
