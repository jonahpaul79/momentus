import Foundation
import Testing
@testable import Momentus

struct MomentusTests {

    @Test func audioUploadProgressReportsFractionAndPercentage() {
        let progress = AudioUploadProgress(bytesSent: 3 * 1024 * 1024, totalBytes: 12 * 1024 * 1024)

        #expect(progress.fraction == 0.25)
        #expect(progress.displayText.contains("25%"))
    }

    @Test func processingStagesExposeUploadBeforeTranscription() {
        #expect(ProcessingState.uploading.stepIndex < ProcessingState.transcribing.stepIndex)
        #expect(ProcessingState.uploading.isInProgress)
    }

    @Test @MainActor func userRetryUsesCurrentModeButAutomaticRecoveryPreservesOriginal() {
        let key = "defaultRecordingMode"
        let original = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(original, forKey: key) }
        UserDefaults.standard.set(RecordingMode.bestQuality.rawValue, forKey: key)
        let privateRecording = Recording(mode: .onDevice, processingState: .failed)

        #expect(RecordingsStore.processingMode(for: privateRecording, userInitiated: true) == .bestQuality)
        #expect(RecordingsStore.processingMode(for: privateRecording, userInitiated: false) == .onDevice)
    }

    @Test func onDeviceProgressProducesVisiblePercentage() {
        let progress = OnDeviceTranscriptionProgress(fraction: 0.42)
        #expect(progress.displayText.contains("42%"))
    }

    @Test func longOnDeviceProgressIdentifiesCurrentDiskChunk() {
        let progress = OnDeviceTranscriptionProgress(
            fraction: 0.25,
            currentChunk: 6,
            totalChunks: 24
        )
        #expect(progress.displayText.contains("part 6 of 24"))
        #expect(progress.displayText.contains("25%"))
    }

    @Test @MainActor func recordingPersistsRemoteTranscriptionCheckpoint() throws {
        let recording = Recording(
            id: UUID(),
            title: "Long meeting",
            processingState: .transcribing,
            transcriptionJobID: "assembly-job-123",
            transcriptionJobCreatedAt: Date()
        )

        let data = try JSONEncoder().encode(recording)
        let decoded = try JSONDecoder().decode(Recording.self, from: data)

        #expect(decoded.transcriptionJobID == "assembly-job-123")
        #expect(decoded.transcriptionJobCreatedAt != nil)
        #expect(decoded.hasUsableTranscriptionCheckpoint)
        #expect(decoded.processingState == .transcribing)
    }

    @Test func staleOrLegacyRemoteCheckpointIsNotReused() {
        let legacy = Recording(transcriptionJobID: "legacy-job-without-date")
        let stale = Recording(
            transcriptionJobID: "stale-job",
            transcriptionJobCreatedAt: Date().addingTimeInterval(-25 * 60 * 60)
        )

        #expect(!legacy.hasUsableTranscriptionCheckpoint)
        #expect(!stale.hasUsableTranscriptionCheckpoint)
    }

    @Test @MainActor func recordingWithoutCheckpointStillDecodes() throws {
        let recording = Recording(id: UUID(), title: "Legacy meeting")
        let encoded = try JSONEncoder().encode(recording)
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "transcriptionJobID")
        json.removeValue(forKey: "transcriptionJobCreatedAt")

        let legacyData = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(Recording.self, from: legacyData)

        #expect(decoded.transcriptionJobID == nil)
        #expect(decoded.transcriptionJobCreatedAt == nil)
        #expect(decoded.title == "Legacy meeting")
    }

    @Test func sanitizerDropsInferredDecisionFromPositiveComment() {
        let decision = MeetingSummarySanitizer.cleanDecision(
            text: "The UI looks better than a previous version, indicating an improvement was accepted or noted positively.",
            context: "Speaker A stated 'The UI looks better' during the recording test.",
            confidence: 0.8
        )

        #expect(decision == nil)
    }

    @Test func sanitizerKeepsExplicitDecision() {
        let decision = MeetingSummarySanitizer.cleanDecision(
            text: "Legacy v1 API sync module is out of scope for the first release.",
            context: "Speaker confirmed the product brief is the correct scope.",
            confidence: 0.95
        )

        #expect(decision?.text == "Legacy v1 API sync module is out of scope for the first release.")
    }

    @Test func sanitizerKeepsExplicitDefaultCommitment() {
        let decision = MeetingSummarySanitizer.cleanDecision(
            text: "If no auth provider decision is made by Thursday, default to Auth0.",
            context: "Speaker set a hard deadline to unblock design work.",
            confidence: 0.96
        )

        #expect(decision?.context == "Speaker set a hard deadline to unblock design work.")
    }

    @Test func providerSpeakerLabelsRequireIdentification() {
        let legacyAssemblySpeaker = Speaker(
            id: UUID(),
            name: "Speaker B",
            isNameInferred: false,
            colorHex: "#6366F1"
        )
        let namedSpeaker = Speaker(
            id: UUID(),
            name: "Jordan Lee",
            isNameInferred: false,
            colorHex: "#6366F1"
        )

        #expect(legacyAssemblySpeaker.requiresIdentification)
        #expect(!namedSpeaker.requiresIdentification)
    }

    @Test func renamingSpeakersUpdatesGeneratedNotes() {
        let recordingID = UUID()
        var summary = MeetingSummary(
            recordingId: recordingID,
            executiveSummary: "Speaker A agreed to send the proposal to Speaker B.",
            decisions: [Decision(id: UUID(), text: "Speaker A approved the plan.", context: nil, confidence: 0.9)],
            actionItems: [ActionItem(
                id: UUID(),
                title: "Send the proposal to Speaker B",
                owner: "Speaker A",
                isOwnerInferred: false,
                dueDate: nil,
                isDueDateInferred: false,
                isCompleted: false,
                confidence: 0.9,
                priority: .medium
            )],
            followUpDraft: "Thanks Speaker A and Speaker B.",
            provider: "Test"
        )

        summary.renameSpeakerReferences(["Speaker A": "Jordan", "Speaker B": "Taylor"])

        #expect(summary.executiveSummary == "Jordan agreed to send the proposal to Taylor.")
        #expect(summary.decisions.first?.text == "Jordan approved the plan.")
        #expect(summary.actionItems.first?.owner == "Jordan")
        #expect(summary.followUpDraft == "Thanks Jordan and Taylor.")

        summary.renameSpeakerReferences(["Jordan": "Morgan"])

        #expect(summary.executiveSummary == "Morgan agreed to send the proposal to Taylor.")
        #expect(summary.decisions.first?.text == "Morgan approved the plan.")
        #expect(summary.actionItems.first?.owner == "Morgan")
        #expect(summary.followUpDraft == "Thanks Morgan and Taylor.")
    }

    @Test func upcomingCalendarMeetingIsNotAttachedToRecording() async {
        let futureMeeting = CalendarMeeting(
            id: UUID(),
            title: "Unrelated Future Meeting",
            startDate: Date().addingTimeInterval(3_600),
            endDate: Date().addingTimeInterval(7_200),
            attendees: ["Wrong Person"]
        )
        let viewModel = RecordViewModel(
            calendarService: TestCalendarContextService(current: [], upcoming: [futureMeeting])
        )

        await viewModel.loadCalendarContext()

        #expect(viewModel.suggestedMeetingTitle == nil)
        #expect(viewModel.suggestedSpeakers.isEmpty)
        #expect(viewModel.upcomingMeetings.map(\.id) == [futureMeeting.id])
    }

    @Test func transcriptChatContextIncludesSpeakerAndTimestamp() {
        let recordingID = UUID()
        let speaker = Speaker(id: UUID(), name: "Jordan", isNameInferred: false, colorHex: "#6366F1")
        let transcript = Transcript(
            id: UUID(),
            recordingId: recordingID,
            segments: [
                TranscriptSegment(
                    id: UUID(),
                    text: "We will ship on Friday.",
                    startTime: 754,
                    endTime: 758,
                    speakerId: speaker.id,
                    confidence: 0.98
                )
            ],
            speakers: [speaker],
            language: "en",
            provider: "Test",
            createdAt: Date()
        )

        #expect(TranscriptChatPrompt.formattedTranscript(transcript) == "[12:34] Jordan: We will ship on Friday.")
    }

    @Test func privateChatPreflightRejectsOversizedTranscript() {
        let transcript = Transcript(
            id: UUID(),
            recordingId: UUID(),
            segments: [
                TranscriptSegment(
                    id: UUID(),
                    text: String(repeating: "discussion ", count: 1_300),
                    startTime: 0,
                    endTime: 60,
                    speakerId: nil,
                    confidence: 0.9
                )
            ],
            speakers: [],
            language: "en",
            provider: "Test",
            createdAt: Date()
        )

        guard case .onDeviceTranscriptTooLong = TranscriptChatPrompt.onDevicePreflightError(for: transcript) else {
            Issue.record("Expected an oversized transcript error")
            return
        }
    }

    @Test func transcriptChatStoreRoundTripsAndDeletesLocalThread() throws {
        let suiteName = "MomentusTests.TranscriptChat.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TranscriptChatStore(defaults: defaults)
        let recordingID = UUID()
        let message = TranscriptChatMessage(role: .user, text: "What was decided?")
        let thread = TranscriptChatThread(
            recordingID: recordingID,
            messages: [message],
            updatedAt: Date()
        )

        store.save(thread)
        let loaded = store.load(recordingID: recordingID)
        #expect(loaded.messages.count == 1)
        #expect(loaded.messages.first?.id == message.id)
        #expect(loaded.messages.first?.text == message.text)

        store.delete(recordingID: recordingID)
        #expect(store.load(recordingID: recordingID).messages.isEmpty)
    }

    @Test func qualityChatPromptAllowsResearchButPrivatePromptDoesNot() {
        let privatePrompt = TranscriptChatPrompt.systemInstructions(
            recordingTitle: "Test",
            transcript: "[0:00] Jordan: Research this later."
        )
        let qualityPrompt = TranscriptChatPrompt.systemInstructions(
            recordingTitle: "Test",
            transcript: "[0:00] Jordan: Research this later.",
            allowsWebResearch: true
        )

        #expect(privatePrompt.contains("Do not claim access to other meetings, email, calendars, the web"))
        #expect(!privatePrompt.contains("You have a web search tool"))
        #expect(qualityPrompt.contains("You have a web search tool"))
        #expect(qualityPrompt.contains("Clearly separate meeting evidence from outside research"))
    }

    @Test func chatPromptRequestsUserContextInsteadOfGuessing() {
        let prompt = TranscriptChatPrompt.systemInstructions(
            recordingTitle: "Test",
            transcript: "[0:00] Jordan: We still need to choose a launch date."
        )

        #expect(prompt.contains("Needs your context:"))
        #expect(prompt.contains("personal judgment or private company context"))
        #expect(prompt.contains("never guess the missing context"))
    }

    @Test @MainActor func openQuestionLaunchCreatesUserTurnAndRequestsAnswer() async throws {
        let suiteName = "MomentusTests.OpenQuestionChat.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(TranscriptChatMode.onDevice.rawValue, forKey: "transcriptChatMode")

        let recordingID = UUID()
        let transcript = Transcript(
            id: UUID(),
            recordingId: recordingID,
            segments: [TranscriptSegment(
                id: UUID(),
                text: "The launch date is still unresolved.",
                startTime: 12,
                endTime: 16,
                speakerId: nil,
                confidence: 0.98
            )],
            speakers: [],
            language: "en",
            provider: "Test",
            createdAt: Date()
        )
        let recording = Recording(id: recordingID, mode: .onDevice, transcript: transcript)
        let store = TranscriptChatStore(defaults: defaults)
        let service = TestTranscriptChatService(response: "The meeting did not settle on a launch date.")
        let viewModel = TranscriptChatViewModel(
            recording: recording,
            chatStore: store,
            preferences: defaults,
            serviceBuilder: { _ in service }
        )

        await viewModel.sendInitialQuestion("  What is the launch date?  ")

        #expect(viewModel.messages.map(\.role) == [.user, .assistant])
        #expect(viewModel.messages.first?.text == "What is the launch date?")
        #expect(viewModel.messages.last?.text == "The meeting did not settle on a launch date.")
        #expect(store.load(recordingID: recordingID).messages == viewModel.messages)
    }

    @Test @MainActor func blockedOpenQuestionStillAppearsInConversation() async throws {
        let suiteName = "MomentusTests.BlockedOpenQuestionChat.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(TranscriptChatMode.onDevice.rawValue, forKey: "transcriptChatMode")

        let recordingID = UUID()
        let transcript = Transcript(
            id: UUID(),
            recordingId: recordingID,
            segments: [TranscriptSegment(
                id: UUID(),
                text: String(repeating: "discussion ", count: 1_300),
                startTime: 0,
                endTime: 60,
                speakerId: nil,
                confidence: 0.9
            )],
            speakers: [],
            language: "en",
            provider: "Test",
            createdAt: Date()
        )
        let recording = Recording(id: recordingID, mode: .onDevice, transcript: transcript)
        let viewModel = TranscriptChatViewModel(
            recording: recording,
            chatStore: TranscriptChatStore(defaults: defaults),
            preferences: defaults,
            serviceBuilder: { _ in TestTranscriptChatService(response: "unused") }
        )

        await viewModel.sendInitialQuestion("What still needs to be decided?")

        #expect(viewModel.messages.count == 1)
        #expect(viewModel.messages.first?.role == .user)
        #expect(viewModel.messages.first?.text == "What still needs to be decided?")
        #expect(viewModel.hasPendingQuestion)
    }

    @Test func paidSummaryPromptDoesNotRequestReviewNotes() {
        #expect(!MeetingSummaryPromptBuilder.systemPrompt.contains("confidenceNotes"))
    }

    @Test @MainActor func quickRecordRequestSurvivesUntilConsumed() {
        _ = QuickRecordLaunchRequest.consumePendingStart()

        QuickRecordLaunchRequest.requestStart()

        #expect(QuickRecordLaunchRequest.consumePendingStart())
        #expect(!QuickRecordLaunchRequest.consumePendingStart())
    }

    @Test func anthropicWebSearchRequestEncodesServerTool() throws {
        let request = AnthropicClient.MessageRequest(
            model: "claude-test",
            maxTokens: 1_000,
            system: "Be helpful.",
            messages: [.init(role: "user", content: "Research this")],
            tools: [.webSearch(maxUses: 3)]
        )
        let data = try JSONEncoder().encode(request)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tools = try #require(json["tools"] as? [[String: Any]])

        #expect(tools.first?["type"] as? String == "web_search_20250305")
        #expect(tools.first?["name"] as? String == "web_search")
        #expect(tools.first?["max_uses"] as? Int == 3)
    }

    @Test func anthropicWebSearchResponseRendersTappableSources() throws {
        let responseJSON = """
        {
          "id": "msg_test",
          "model": "claude-test",
          "stop_reason": "end_turn",
          "content": [{
            "type": "text",
            "text": "The current answer is 42.",
            "citations": [{
              "type": "web_search_result_location",
              "url": "https://example.com/research",
              "title": "Example [Research]",
              "cited_text": "The answer is 42."
            }]
          }],
          "usage": {
            "input_tokens": 100,
            "output_tokens": 25,
            "server_tool_use": { "web_search_requests": 1 }
          }
        }
        """
        let response = try JSONDecoder().decode(
            AnthropicClient.MessageResponse.self,
            from: Data(responseJSON.utf8)
        )

        #expect(response.stopReason == "end_turn")
        #expect(response.webSearchRequestCount == 1)
        #expect(response.renderedWebSearchText.contains("[[1]](https://example.com/research)"))
        #expect(response.renderedWebSearchText.contains("[Example \\[Research\\]](https://example.com/research)"))
    }

}

private final class TestCalendarContextService: CalendarContextService {
    let current: [CalendarMeeting]
    let upcoming: [CalendarMeeting]

    init(current: [CalendarMeeting], upcoming: [CalendarMeeting]) {
        self.current = current
        self.upcoming = upcoming
    }

    func requestAccess() async -> Bool { true }
    func getCurrentMeetings() async -> [CalendarMeeting] { current }
    func getUpcomingMeetings() async -> [CalendarMeeting] { upcoming }
}

private final class TestTranscriptChatService: TranscriptChatService {
    private let response: String
    let providerName = "Test"
    let isOnDevice = true

    init(response: String) {
        self.response = response
    }

    func reply(
        to messages: [TranscriptChatMessage],
        transcript: Transcript,
        recordingTitle: String
    ) async throws -> String {
        response
    }
}
