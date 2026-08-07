import Foundation
import Testing
@testable import Momentus

struct MomentusTests {

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
    }

}
