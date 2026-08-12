import Foundation

@Observable final class TranscriptChatViewModel {
    typealias ServiceBuilder = (TranscriptChatMode) throws -> any TranscriptChatService

    let recording: Recording
    var messages: [TranscriptChatMessage]
    var draft = ""
    var isResponding = false
    var error: TranscriptChatError?
    var selectedMode: TranscriptChatMode {
        didSet {
            preferences.set(selectedMode.rawValue, forKey: Self.modePreferenceKey)
            if oldValue != selectedMode { error = nil }
        }
    }

    private static let modePreferenceKey = "transcriptChatMode"
    private let chatStore: TranscriptChatStore
    private let preferences: UserDefaults
    private let serviceBuilder: ServiceBuilder

    init(
        recording: Recording,
        chatStore: TranscriptChatStore = TranscriptChatStore(),
        preferences: UserDefaults = .standard,
        serviceBuilder: ServiceBuilder? = nil
    ) {
        self.recording = recording
        self.chatStore = chatStore
        self.preferences = preferences
        self.serviceBuilder = serviceBuilder ?? { mode in
            try ServiceFactory.makeTranscriptChatService(for: mode)
        }
        self.messages = chatStore.load(recordingID: recording.id).messages
        let savedMode = preferences.string(forKey: Self.modePreferenceKey)
            .flatMap(TranscriptChatMode.init(rawValue:))
        self.selectedMode = savedMode ?? (recording.mode == .onDevice ? .onDevice : .bestQuality)
    }

    var transcript: Transcript? { recording.transcript }

    var hasAnthropicKey: Bool { ServiceFactory.isAnthropicChatConfigured }

    var hasPendingQuestion: Bool { messages.last?.role == .user }

    var blockingError: TranscriptChatError? {
        guard let transcript else { return .emptyTranscript }
        switch selectedMode {
        case .onDevice:
            return TranscriptChatPrompt.onDevicePreflightError(for: transcript)
        case .bestQuality:
            return hasAnthropicKey ? nil : .missingAnthropicAPIKey
        }
    }

    var canSend: Bool {
        !isResponding
            && blockingError == nil
            && !hasPendingQuestion
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func send() async {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isResponding, blockingError == nil, !hasPendingQuestion else { return }

        draft = ""
        error = nil
        messages.append(TranscriptChatMessage(role: .user, text: question))
        persist()
        await requestReply()
    }

    /// Starts a chat launched from an open question. The question is persisted as
    /// a user turn even when the selected provider needs configuration, so the
    /// sheet never falls back to an unrelated empty-chat state.
    func sendInitialQuestion(_ rawQuestion: String) async {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isResponding else { return }

        draft = ""
        error = nil
        messages.append(TranscriptChatMessage(role: .user, text: question))
        persist()

        if let blockingError {
            error = blockingError
            return
        }

        await requestReply()
    }

    func retryPendingQuestion() async {
        guard hasPendingQuestion, !isResponding, blockingError == nil else { return }
        error = nil
        await requestReply()
    }

    func useBestQualityAndRetry() async {
        selectedMode = .bestQuality
        guard hasAnthropicKey else {
            error = .missingAnthropicAPIKey
            return
        }
        if hasPendingQuestion {
            await retryPendingQuestion()
        }
    }

    func askSuggestion(_ suggestion: String) async {
        guard !hasPendingQuestion else { return }
        draft = suggestion
        await send()
    }

    func clearConversation() {
        messages = []
        error = nil
        chatStore.delete(recordingID: recording.id)
    }

    private func requestReply() async {
        guard let transcript else {
            error = .emptyTranscript
            return
        }

        isResponding = true
        defer { isResponding = false }

        do {
            let service = try serviceBuilder(selectedMode)
            let response = try await service.reply(
                to: messages,
                transcript: transcript,
                recordingTitle: recording.title
            )
            messages.append(TranscriptChatMessage(
                role: .assistant,
                text: response,
                mode: selectedMode
            ))
            persist()
            HapticStyle.success.trigger()
        } catch let chatError as TranscriptChatError {
            error = chatError
        } catch let underlyingError {
            error = .providerFailure(underlyingError.localizedDescription)
        }
    }

    private func persist() {
        chatStore.save(TranscriptChatThread(
            recordingID: recording.id,
            messages: messages,
            updatedAt: Date()
        ))
    }
}
