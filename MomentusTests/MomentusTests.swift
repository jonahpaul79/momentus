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

}
