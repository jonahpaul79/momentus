# Momentus — Claude Code Context

IRL meeting recorder for Apple Watch + iPhone. Dark-mode-first SwiftUI, iOS 26.5 + watchOS 26.5. No backend yet — all providers are mocked.

---

## Stack

| | |
|---|---|
| Language | Swift 5.10 / Xcode 26.5 |
| UI | SwiftUI (`@Observable`, NavigationStack, TabView) |
| Concurrency | Swift structured concurrency — `async/await`, `Task` |
| State | `@Observable` + `.environment(...)` — no `ObservableObject` or `@StateObject` |
| Settings | `@AppStorage` (UserDefaults) |
| Data | In-memory `RecordingsStore` + `JSONEncoder` to UserDefaults. No CoreData/SwiftData yet. |
| Swift flags | `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES` |

**No external dependencies.** All providers are mocked until real integrations are added.

---

## Architecture

**MVVM.** Views observe `@Observable` view models. Two global objects live for the lifetime of the app and are injected as environment values from `ContentView`:

```swift
// ContentView.swift — the only place these are created
@State private var themeManager = ThemeManager()
@State private var store = RecordingsStore()

.environment(themeManager)
.environment(store)
```

**Every view that needs them reads:**
```swift
@Environment(ThemeManager.self) private var themeManager
@Environment(RecordingsStore.self) private var store
```

`RecordViewModel` is a `@State` inside `RecordHomeView`. It receives `store` via `vm.configure(store:)` in `.task {}`. There is no DI container.

---

## File Map

```
Momentus/
  MomentusApp.swift              entry point, nothing interesting
  ContentView.swift              TabView, creates ThemeManager + RecordingsStore
  Theme/AppTheme.swift           ALL theme types + ThemeManager + presets
  Models/Models.swift            ALL model types — Recording, Transcript, MeetingSummary, etc.
  Services/ServiceProtocols.swift  ALL provider protocols + provider/retention enums
  Services/Mock/MockServices.swift RecordingsStore + all mock service impls
  MockData/MockMeetings.swift    4 realistic sample recordings w/ real transcripts
  Features/Record/
    RecordViewModel.swift        timer, waveform loop, async processing pipeline
    RecordHomeView.swift         hero screen — record button, mode pill, calendar card
    ActiveRecordingView.swift    full-screen recording — orb, waveform, controls
    ProcessingView.swift         step-by-step processing progress
  Features/Notes/
    NotesViewModel.swift         search + filter logic only
    NotesListView.swift          recording list with filter chips
    MeetingSummaryDetailView.swift  the main value screen — all summary sections
    TranscriptDetailView.swift   speaker-labeled transcript with search
  Features/Settings/SettingsView.swift   mode, retention, provider, theme pickers
  Features/Onboarding/OnboardingView.swift  5-page first-run flow
  Shared/Components/WaveformView.swift   WaveformView, StaticWaveformView, RecordingOrb
  Shared/Extensions/ViewExtensions.swift surfaceCard modifier, ModeBadge, ConfidenceBadge, haptics
Momentus Watch App/
  WatchTheme.swift               lightweight WatchTheme struct + timerString extension
  WatchViewModel.swift           watch recording state + WatchConnectivity stubs
  WatchHomeView/ActiveRecordingView/SavedView.swift
```

---

## Design System

**Never use hardcoded colors, spacing, or radius values.** Always read from the active theme.

```swift
// In any view:
@Environment(ThemeManager.self) private var themeManager

var body: some View {
    let t = themeManager.currentTheme   // ← assign once per body for readability

    Text("Hello")
        .font(t.typography.headlineMedium)
        .foregroundStyle(t.colors.textPrimary)
        .padding(t.spacing.l)
        .background(t.colors.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: t.radius.card))
}
```

**Theme token layers:**
- `backgroundPrimary/Secondary` — app/screen backgrounds
- `surfacePrimary/Secondary/Tertiary` — card and sheet backgrounds, lightest is tertiary
- `accentPrimary` — indigo/crimson, CTAs and active states
- `accentRecording` — red/coral, only for active recording UI
- `accentSuccess/Warning/Error` — semantic states
- `textPrimary/Secondary/Tertiary` — hierarchy; tertiary is near-invisible metadata
- `divider/border/borderStrong` — separators

**Reusable card pattern:**
```swift
VStack { ... }
    .padding(t.spacing.l)
    .surfaceCard()           // background + clip + border + shadow in one modifier
    .environment(themeManager)  // surfaceCard reads ThemeManager via environment
```

**Switch theme:**
```swift
themeManager.currentPreset = .graphiteCrimson  // persisted to UserDefaults automatically
```

---

## Adding a Provider

All AI providers are behind protocols in `Services/ServiceProtocols.swift`. The mock impls live in `Services/Mock/MockServices.swift`. Real impls go in `Services/Providers/` (create this folder).

**To add a transcription provider:**

1. Create `Services/Providers/YourTranscriptionService.swift`
2. Conform to `TranscriptionService`:
   ```swift
   final class YourTranscriptionService: TranscriptionService {
       let providerName = "YourProvider"
       let isOnDevice = false   // or true if on-device
       func transcribe(audioFileID: String, recordingId: UUID) async throws -> Transcript { ... }
   }
   ```
3. In `RecordViewModel.init(...)`, swap `MockTranscriptionService()` for your impl.
4. Add the case to `TranscriptionProvider` enum in `ServiceProtocols.swift`.
5. Add privacy labels to the new enum case.

**Same pattern for summary providers** — conform to `SummaryService`, swap in `RecordViewModel.init`.

**API keys must go in Keychain** — never `UserDefaults` or source code. See `// TODO: Keychain` in `SettingsView.swift`.

---

## Recording → Notes Pipeline

`RecordViewModel.stopRecording()` runs this pipeline sequentially. Each step updates `RecordingsStore` so the Notes list reflects partial state while processing:

```
stopRecording()
  → RecordingService.stopRecording()        → audioFileID (String)
  → TranscriptionService.transcribe(...)    → Transcript
  → SummaryService.summarize(...)           → MeetingSummary
  → Recording.processingState = .completed
  → RecordingsStore.update(recording)
```

Each step updates `processingStepIndex` which drives `ProcessingView`'s animated stepper.

---

## Conventions

- **Theme access:** `let t = themeManager.currentTheme` at the top of `body`, then use `t.*` everywhere.
- **Haptics:** Always use `HapticStyle.trigger()` (defined in `ViewExtensions.swift`) — never call `UIImpactFeedbackGenerator` directly.
- **Async mutations from buttons:** `Button { Task { await vm.someAction() } }` — the `Task` bridges the sync button closure to async.
- **No sheet/nav from ViewModels:** All presentation state (`@State var showingX`) lives in views, not ViewModels.
- **`@Bindable` for ViewModels in children:** When passing a ViewModel down to a child view that needs bindings, use `@Bindable var vm: RecordViewModel` (requires `@Observable`).
- **Environment must be forwarded:** `surfaceCard()` and badge components read `ThemeManager` from environment — always add `.environment(themeManager)` when using them outside the main nav stack.

---

## Swift 6 / iOS 26 Gotchas

- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` means every type is implicitly `@MainActor`. Timer callbacks, `Task {}` closures, and service methods all run on main actor unless explicitly marked `nonisolated`. Mock services using `Task.sleep` are fine. Real network providers should consider `nonisolated` or actor-isolated types.
- `@Observable` does not work with `@AppStorage` directly. Use `UserDefaults` in `didSet` for observable + persisted values (see `ThemeManager`).
- `PBXFileSystemSynchronizedRootGroup` is used — files added to the `Momentus/` or `Momentus Watch App/` directories on disk are automatically included in the build without editing `project.pbxproj`.

---

## What Not To Do

- Don't hardcode colors, spacing, or fonts. Use theme tokens.
- Don't create singleton services (`ServiceLocator.shared`, `AudioEngine.shared`). Pass via init or environment.
- Don't put presentation state (sheet booleans, nav paths) in ViewModels.
- Don't add real API calls without first adding Keychain storage for keys.
- Don't modify `project.pbxproj` to add Swift files — just create them in the right directory.
- Don't use `ObservableObject` / `@StateObject` / `@Published` — the codebase uses `@Observable` throughout.
