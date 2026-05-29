import Foundation

// MARK: - Mock Sample Data

enum MockMeetings {

    // MARK: Speakers

    static let speakerJonah = Speaker(id: UUID(uuidString: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")!, name: "Jonah", isNameInferred: false, colorHex: "#6C63FF")
    static let speakerJesse = Speaker(id: UUID(uuidString: "B2C3D4E5-F6A7-8901-BCDE-F12345678901")!, name: "Jesse", isNameInferred: false, colorHex: "#00D4FF")
    static let speakerMaya = Speaker(id: UUID(uuidString: "C3D4E5F6-A7B8-9012-CDEF-123456789012")!, name: "Maya", isNameInferred: true, colorHex: "#00C896")
    static let speakerUnknown = Speaker(id: UUID(uuidString: "D4E5F6A7-B8C9-0123-DEF0-234567890123")!, name: "Speaker 4", isNameInferred: true, colorHex: "#FFB800")

    // MARK: - Meeting 1: Mobile App Kickoff

    static let mobileKickoffRecording: Recording = {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let start = Calendar.current.date(byAdding: .day, value: -2, to: Date())!
            .noon
        let end = start.addingTimeInterval(72 * 60)

        return Recording(
            id: id,
            title: "Mobile App Kickoff",
            startedAt: start,
            endedAt: end,
            mode: .bestQuality,
            micSource: .iPhone,
            audioFileID: "mock_audio_kickoff",
            processingState: .completed,
            transcript: mobileKickoffTranscript,
            summary: mobileKickoffSummary,
            isFavorite: true,
            markers: [420, 1620, 2940]
        )
    }()

    static let mobileKickoffTranscript: Transcript = {
        let recId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        return Transcript(
            id: UUID(),
            recordingId: recId,
            segments: [
                .init(id: UUID(), text: "Alright, let's get started. Thanks for joining. We're here to kick off the mobile app rebuild project. I want to make sure we leave with clear ownership on the big pieces.", startTime: 0, endTime: 12, speakerId: speakerJonah.id, confidence: 0.97),
                .init(id: UUID(), text: "Before we dive in — can we align on scope? Because I got two very different briefs from product and from engineering.", startTime: 14, endTime: 22, speakerId: speakerJesse.id, confidence: 0.94),
                .init(id: UUID(), text: "That's exactly what we're here to fix. The product brief is the correct one. Engineering's version was from Q3 and pre-dates the pivot.", startTime: 23, endTime: 31, speakerId: speakerJonah.id, confidence: 0.96),
                .init(id: UUID(), text: "Okay. So we're dropping the legacy sync module entirely?", startTime: 32, endTime: 36, speakerId: speakerMaya.id, confidence: 0.91),
                .init(id: UUID(), text: "Yes. We decided last week that anything relying on the v1 API is out of scope for the first release. The new architecture is REST plus WebSockets for real-time.", startTime: 37, endTime: 48, speakerId: speakerJonah.id, confidence: 0.95),
                .init(id: UUID(), text: "That's a significant change to the data layer. We'll need to rewrite the caching strategy completely.", startTime: 49, endTime: 57, speakerId: speakerMaya.id, confidence: 0.88),
                .init(id: UUID(), text: "Agreed. Maya, can you own the data layer architecture doc? I want a first draft before the end of next week.", startTime: 58, endTime: 65, speakerId: speakerJonah.id, confidence: 0.97),
                .init(id: UUID(), text: "I can do that. I'll also pull in the Android lead since they'll need to mirror whatever pattern we settle on.", startTime: 66, endTime: 73, speakerId: speakerMaya.id, confidence: 0.92),
                .init(id: UUID(), text: "Good call. Jesse, you're owning the design system handoff. When can we expect component specs?", startTime: 74, endTime: 80, speakerId: speakerJonah.id, confidence: 0.95),
                .init(id: UUID(), text: "I need two days to audit what we already have. Realistically, full specs by end of week two. But I can get you the navigation patterns and core components by Friday.", startTime: 81, endTime: 93, speakerId: speakerJesse.id, confidence: 0.90),
                .init(id: UUID(), text: "That works. One open question I want flagged — do we have a decision on third-party auth yet? I've heard both Clerk and Auth0 mentioned.", startTime: 94, endTime: 104, speakerId: speakerMaya.id, confidence: 0.87),
                .init(id: UUID(), text: "Not decided. Legal is still reviewing both. I'll chase that down this week. We can't finalize the onboarding screens until that's settled.", startTime: 105, endTime: 115, speakerId: speakerJonah.id, confidence: 0.94),
                .init(id: UUID(), text: "One risk I want to flag — if the auth decision slips, it blocks Jesse's onboarding component work which blocks the design review.", startTime: 116, endTime: 125, speakerId: speakerUnknown.id, confidence: 0.63),
                .init(id: UUID(), text: "Noted. I'll escalate to legal today and set a hard deadline of next Thursday for the auth decision. If we don't have it by then, we default to Auth0 and move on.", startTime: 126, endTime: 138, speakerId: speakerJonah.id, confidence: 0.96),
            ],
            speakers: [speakerJonah, speakerJesse, speakerMaya, speakerUnknown],
            language: "en-US",
            provider: "Deepgram",
            createdAt: Date().addingTimeInterval(-3600)
        )
    }()

    static let mobileKickoffSummary: MeetingSummary = {
        let recId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        return MeetingSummary(
            id: UUID(),
            recordingId: recId,
            suggestedTitle: "Mobile App Kickoff",
            executiveSummary: "Kicked off the mobile app rebuild project. Aligned on scope: the v1 API sync module is dropped and the new architecture uses REST + WebSockets. Key owners assigned for data layer architecture and design system handoff. Auth provider decision is the critical open blocker — Jonah to resolve with legal by Thursday or default to Auth0.",
            decisions: [
                Decision(id: UUID(), text: "Legacy v1 API sync module is out of scope for the first release.", context: "Pre-dates the product pivot decided last quarter.", confidence: 0.97),
                Decision(id: UUID(), text: "New architecture will use REST + WebSockets for real-time updates.", context: nil, confidence: 0.95),
                Decision(id: UUID(), text: "If auth provider decision is not made by Thursday, default to Auth0.", context: "Hard deadline set to unblock design work.", confidence: 0.96),
            ],
            actionItems: [
                ActionItem(id: UUID(), title: "Write data layer architecture doc (draft by end of next week)", owner: "Maya", isOwnerInferred: false, dueDate: Calendar.current.date(byAdding: .day, value: 7, to: Date()), isDueDateInferred: true, isCompleted: false, confidence: 0.95, priority: .high),
                ActionItem(id: UUID(), title: "Pull in Android lead to align on data layer pattern", owner: "Maya", isOwnerInferred: false, dueDate: nil, isDueDateInferred: false, isCompleted: false, confidence: 0.91, priority: .medium),
                ActionItem(id: UUID(), title: "Deliver navigation patterns and core component specs", owner: "Jesse", isOwnerInferred: false, dueDate: Calendar.current.date(byAdding: .day, value: 4, to: Date()), isDueDateInferred: true, isCompleted: false, confidence: 0.90, priority: .high),
                ActionItem(id: UUID(), title: "Chase legal for auth provider decision (Clerk vs Auth0)", owner: "Jonah", isOwnerInferred: false, dueDate: Calendar.current.date(byAdding: .day, value: 2, to: Date()), isDueDateInferred: true, isCompleted: false, confidence: 0.96, priority: .high),
            ],
            openQuestions: [
                OpenQuestion(id: UUID(), text: "Which auth provider will be selected — Clerk or Auth0?", owner: "Jonah", priority: .critical),
                OpenQuestion(id: UUID(), text: "Do Android and iOS need to use identical caching strategies or can they diverge?", owner: "Maya", priority: .medium),
            ],
            risks: [
                Risk(id: UUID(), title: "Auth decision delay blocks onboarding screens", description: "If legal review of auth providers extends past Thursday, Jesse's onboarding component work stalls, delaying the design review milestone.", severity: .high),
            ],
            followUpDraft: """
Hi team,

Quick follow-up from today's kickoff.

**Decisions made:**
- Legacy v1 sync is dropped from scope
- New architecture: REST + WebSockets
- Auth default: Auth0 if no decision by Thursday

**Your actions:**
- Maya: Data layer architecture doc draft by end of next week. Loop in Android lead.
- Jesse: Nav patterns + core components by Friday. Full specs week 2.
- Jonah: Chase legal on auth by Thursday EOD.

Let me know if I've missed anything.

— Jonah
""",
            provider: "Claude",
            createdAt: Date().addingTimeInterval(-3500),
            confidenceNotes: ["Speaker 4 segments have lower confidence — consider verifying attribution."]
        )
    }()

    // MARK: - Meeting 2: Product Discovery Interview

    static let discoveryInterviewRecording: Recording = {
        let start = Calendar.current.date(byAdding: .day, value: -5, to: Date())!.noon
        let end = start.addingTimeInterval(45 * 60)
        return Recording(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            title: "Product Discovery: Healthcare Portal",
            startedAt: start,
            endedAt: end,
            mode: .onDevice,
            micSource: .watch,
            audioFileID: "mock_audio_discovery",
            processingState: .completed,
            transcript: discoveryTranscript,
            summary: discoverySummary,
            isFavorite: false,
            markers: [180, 1080]
        )
    }()

    static let discoveryTranscript: Transcript = {
        let recId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        return Transcript(
            id: UUID(),
            recordingId: recId,
            segments: [
                .init(id: UUID(), text: "Tell me about the last time you tried to book an appointment online with your health system.", startTime: 0, endTime: 7, speakerId: speakerJonah.id, confidence: 0.96),
                .init(id: UUID(), text: "It was a nightmare. I had to log into three different portals depending on which doctor I was seeing. My GP uses one system, the specialist is on MyChart, and then physical therapy is on some other thing I've never heard of.", startTime: 8, endTime: 23, speakerId: speakerJesse.id, confidence: 0.93),
                .init(id: UUID(), text: "How did that make you feel?", startTime: 24, endTime: 26, speakerId: speakerJonah.id, confidence: 0.98),
                .init(id: UUID(), text: "Honestly? Like the health system doesn't actually care about me as a patient. Like I'm doing administrative work that should be their job.", startTime: 27, endTime: 37, speakerId: speakerJesse.id, confidence: 0.91),
                .init(id: UUID(), text: "What would the ideal experience look like for you?", startTime: 38, endTime: 41, speakerId: speakerJonah.id, confidence: 0.97),
                .init(id: UUID(), text: "One app. My entire care history in one place. I should be able to message any of my doctors, see all my upcoming appointments, and get lab results without logging into three different things.", startTime: 42, endTime: 57, speakerId: speakerJesse.id, confidence: 0.89),
                .init(id: UUID(), text: "When you think about trust with a health app — what would make you trust it or not trust it?", startTime: 58, endTime: 66, speakerId: speakerJonah.id, confidence: 0.95),
                .init(id: UUID(), text: "The brand matters. If it's from my hospital I already sort of trust it. But if it's some startup I've never heard of, I'm not putting my health data in there. And honestly notifications are the quickest way to lose my trust — if it starts spamming me I'm deleting it.", startTime: 67, endTime: 88, speakerId: speakerJesse.id, confidence: 0.85),
            ],
            speakers: [speakerJonah, speakerJesse],
            language: "en-US",
            provider: "Apple On-Device",
            createdAt: Date().addingTimeInterval(-86400 * 5)
        )
    }()

    static let discoverySummary: MeetingSummary = {
        let recId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        return MeetingSummary(
            id: UUID(),
            recordingId: recId,
            suggestedTitle: "Product Discovery: Healthcare Portal",
            executiveSummary: "Discovery interview exploring patient experience with digital health portals. Key pain point: fragmented portal landscape requires patients to manage 3+ separate logins. Core desire is a unified view of appointments, messaging, and lab results. Brand trust and notification hygiene are primary trust drivers.",
            decisions: [],
            actionItems: [
                ActionItem(id: UUID(), title: "Add portal fragmentation as top pain point in insight board", owner: nil, isOwnerInferred: true, dueDate: nil, isDueDateInferred: false, isCompleted: false, confidence: 0.88, priority: .medium),
                ActionItem(id: UUID(), title: "Design trust signal audit for healthcare digital front door", owner: nil, isOwnerInferred: true, dueDate: nil, isDueDateInferred: false, isCompleted: false, confidence: 0.82, priority: .low),
            ],
            openQuestions: [
                OpenQuestion(id: UUID(), text: "What is the typical number of patient portals a typical user manages?", owner: nil, priority: .high),
                OpenQuestion(id: UUID(), text: "How do notification preferences differ between age groups?", owner: nil, priority: .medium),
            ],
            risks: [],
            followUpDraft: "Will follow up with participant about interest in usability study for the unified portal prototype.",
            provider: "Apple Foundation Models",
            createdAt: Date().addingTimeInterval(-86400 * 5 + 3600),
            confidenceNotes: ["On-device transcription — some segments have lower confidence due to background noise."]
        )
    }()

    // MARK: - Meeting 3: AI Recorder Product Discussion

    static let aiRecorderDiscussionRecording: Recording = {
        let start = Calendar.current.date(byAdding: .hour, value: -3, to: Date())!
        let end = start.addingTimeInterval(38 * 60)
        return Recording(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            title: "AI Meeting Recorder — Strategy",
            startedAt: start,
            endedAt: end,
            mode: .hybrid,
            micSource: .iPhone,
            audioFileID: "mock_audio_ai_recorder",
            processingState: .completed,
            transcript: nil,
            summary: aiRecorderSummary,
            isFavorite: false,
            markers: []
        )
    }()

    static let aiRecorderSummary: MeetingSummary = {
        let recId = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        return MeetingSummary(
            id: UUID(),
            recordingId: recId,
            suggestedTitle: "AI Meeting Recorder — Strategy",
            executiveSummary: "Discussed positioning and differentiation for an AI meeting recorder targeting IRL (in-person) conversations. Competitors like Granola cover virtual meetings well but IRL capture is underserved. Watch-first capture is the key differentiator. Privacy-first positioning is both a feature and a trust signal. Agreed to build an MVP focused on Watch → iPhone capture with mock providers.",
            decisions: [
                Decision(id: UUID(), text: "Watch is the primary capture trigger — fastest possible IRL activation.", context: "iPhone often in pocket or bag; Watch is always on wrist.", confidence: 0.97),
                Decision(id: UUID(), text: "Privacy-first will be the primary positioning angle.", context: "Differentiates from cloud-heavy competitors.", confidence: 0.95),
                Decision(id: UUID(), text: "MVP scope: mock providers only — no live API calls until secure key management is implemented.", context: nil, confidence: 0.98),
            ],
            actionItems: [
                ActionItem(id: UUID(), title: "Build MVP SwiftUI app with full mock recording flow", owner: "Jonah", isOwnerInferred: false, dueDate: Calendar.current.date(byAdding: .day, value: 14, to: Date()), isDueDateInferred: true, isCompleted: false, confidence: 0.97, priority: .high),
                ActionItem(id: UUID(), title: "Research SpeechAnalyzer API for on-device transcription", owner: "Jonah", isOwnerInferred: false, dueDate: nil, isDueDateInferred: false, isCompleted: false, confidence: 0.91, priority: .high),
                ActionItem(id: UUID(), title: "Competitive teardown: Granola, Otter, Fireflies IRL use cases", owner: nil, isOwnerInferred: true, dueDate: nil, isDueDateInferred: false, isCompleted: false, confidence: 0.85, priority: .medium),
            ],
            openQuestions: [
                OpenQuestion(id: UUID(), text: "What is the right price point — freemium with cloud paywall, or flat monthly?", owner: nil, priority: .high),
                OpenQuestion(id: UUID(), text: "Will Apple Foundation Models be good enough for meeting summarization?", owner: nil, priority: .high),
                OpenQuestion(id: UUID(), text: "How do we handle multi-device handoff if recording starts on Watch?", owner: nil, priority: .medium),
            ],
            risks: [
                Risk(id: UUID(), title: "On-device model quality gap", description: "Apple Foundation Models may not produce summary quality competitive with Claude or GPT-4. May force users toward cloud mode earlier than desired.", severity: .medium),
                Risk(id: UUID(), title: "App Store background audio entitlement", description: "Background recording requires special entitlement that may require justification in App Store review.", severity: .high),
            ],
            followUpDraft: "Following up with a design brief and architecture doc for the MVP. Will share the SwiftUI project structure for review before end of week.",
            provider: "Claude",
            createdAt: Date().addingTimeInterval(-2 * 3600),
            confidenceNotes: []
        )
    }()

    // MARK: - Meeting 4: Processing State Demo

    static let processingRecording: Recording = {
        let start = Date().addingTimeInterval(-5 * 60)
        return Recording(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            title: "Client Workshop Prep",
            startedAt: start,
            endedAt: Date(),
            mode: .bestQuality,
            micSource: .iPhone,
            audioFileID: "mock_audio_workshop",
            processingState: .transcribing,
            transcript: nil,
            summary: nil,
            isFavorite: false,
            markers: []
        )
    }()

    // MARK: - All Sample Recordings

    static var sampleRecordings: [Recording] {
        [mobileKickoffRecording, discoveryInterviewRecording, aiRecorderDiscussionRecording, processingRecording]
    }

    // MARK: - Sample Calendar Meetings

    static var sampleCalendarMeetings: [CalendarMeeting] {
        let now = Date()
        return [
            CalendarMeeting(
                id: UUID(),
                title: "Product sync with Jesse",
                startDate: now.addingTimeInterval(-2 * 60),
                endDate: now.addingTimeInterval(28 * 60),
                attendees: ["Jonah", "Jesse"]
            ),
            CalendarMeeting(
                id: UUID(),
                title: "Healthcare portal discovery call",
                startDate: now.addingTimeInterval(45 * 60),
                endDate: now.addingTimeInterval(90 * 60),
                attendees: ["Jonah", "Client"]
            ),
        ]
    }
}

// MARK: - Date helpers

private extension Date {
    var noon: Date {
        Calendar.current.date(bySettingHour: 10, minute: 30, second: 0, of: self) ?? self
    }
}
