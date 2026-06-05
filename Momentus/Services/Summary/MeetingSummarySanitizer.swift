import Foundation

enum MeetingSummarySanitizer {
    static func cleanDecision(
        text rawText: String,
        context rawContext: String?,
        confidence: Float
    ) -> Decision? {
        let text = clean(rawText)
        guard !text.isEmpty, confidence >= 0.55 else { return nil }

        let context = rawContext.flatMap { cleanedOptional($0) }
        let evidence = ([text] + [context].compactMap { $0 })
            .joined(separator: " ")
            .lowercased()

        guard !looksLikeInferredDecision(evidence), hasDecisionEvidence(evidence) else {
            return nil
        }

        return Decision(id: UUID(), text: text, context: context, confidence: confidence)
    }

    static func cleanActionItem(
        title rawTitle: String,
        owner rawOwner: String?,
        isOwnerInferred: Bool,
        confidence: Float,
        priority: ActionItem.Priority
    ) -> ActionItem? {
        let title = clean(rawTitle)
        guard !title.isEmpty, confidence >= 0.55 else { return nil }

        return ActionItem(
            id: UUID(),
            title: title,
            owner: rawOwner.flatMap { cleanedOptional($0) },
            isOwnerInferred: isOwnerInferred,
            dueDate: nil,
            isDueDateInferred: false,
            isCompleted: false,
            confidence: confidence,
            priority: priority
        )
    }

    static func cleanOpenQuestion(
        text rawText: String,
        owner rawOwner: String?,
        priority: OpenQuestion.Priority
    ) -> OpenQuestion? {
        let text = clean(rawText)
        guard !text.isEmpty else { return nil }
        return OpenQuestion(
            id: UUID(),
            text: text,
            owner: rawOwner.flatMap { cleanedOptional($0) },
            priority: priority
        )
    }

    static func cleanRisk(
        title rawTitle: String,
        description rawDescription: String,
        severity: Risk.Severity
    ) -> Risk? {
        let title = clean(rawTitle)
        let description = clean(rawDescription)
        guard !title.isEmpty, !description.isEmpty else { return nil }
        return Risk(id: UUID(), title: title, description: description, severity: severity)
    }

    static func cleanedOptional(_ raw: String) -> String? {
        let value = clean(raw)
        return value.isEmpty || value.lowercased() == "null" ? nil : value
    }

    private static func clean(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hasDecisionEvidence(_ evidence: String) -> Bool {
        let markers = [
            "decided", "decision", "agreed", "approved", "accepted", "selected",
            "chose", "chosen", "finalized", "confirmed", "resolved", "settled",
            "greenlit", "signed off", "go with", "going with", "default to",
            "out of scope", "in scope", "will use", "will be", "we will",
            "we'll", "we are going to", "we're going to", "moving forward",
            "set a hard deadline", "is the correct"
        ]
        return markers.contains { evidence.contains($0) }
    }

    private static func looksLikeInferredDecision(_ evidence: String) -> Bool {
        let inferenceMarkers = [
            "indicating", "suggesting", "suggests", "implies", "appears to",
            "seems to", "may indicate", "noted positively", "looks better than",
            "was likely", "could mean", "possibly"
        ]
        return inferenceMarkers.contains { evidence.contains($0) }
    }
}
