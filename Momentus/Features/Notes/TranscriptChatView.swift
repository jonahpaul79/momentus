import SwiftUI
import UIKit

struct TranscriptChatView: View {
    private enum PendingChatAction {
        case send
        case initialQuestion(String)
        case suggestion(String)
        case retry
    }

    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: TranscriptChatViewModel
    @State private var showingClearConfirmation = false
    @State private var showingCloudAIConsent = false
    @State private var handledInitialLaunch = false
    @State private var pendingChatAction: PendingChatAction?
    @State private var copiedMessageID: UUID?
    @FocusState private var composerIsFocused: Bool

    private let initialQuestion: String?

    private let suggestions = [
        "What were the key decisions?",
        "What should I do next?",
        "Draft a follow-up message"
    ]

    init(
        recording: Recording,
        initialQuestion: String? = nil
    ) {
        let question = initialQuestion?.trimmingCharacters(in: .whitespacesAndNewlines)
        let viewModel = TranscriptChatViewModel(recording: recording)
        _viewModel = State(initialValue: viewModel)
        self.initialQuestion = question?.isEmpty == false ? question : nil
    }

    var body: some View {
        let t = themeManager.currentTheme
        @Bindable var viewModel = viewModel

        NavigationStack {
            VStack(spacing: 0) {
                modeSelector(viewModel: $viewModel, t: t)
                Divider().overlay(t.colors.divider)
                conversation(t)
                Divider().overlay(t.colors.divider)
                composer(t)
            }
            .background(t.colors.backgroundPrimary)
            .navigationTitle("Ask Momentus")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(t.colors.textSecondary)
                }
                if !viewModel.messages.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            Button(role: .destructive) {
                                showingClearConfirmation = true
                            } label: {
                                Label("Clear conversation", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundStyle(t.colors.textSecondary)
                        }
                        .disabled(viewModel.isResponding)
                    }
                }
            }
            .alert("Clear this conversation?", isPresented: $showingClearConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Clear", role: .destructive) { viewModel.clearConversation() }
            } message: {
                Text("The chat history for this meeting will be removed from this device.")
            }
            .task {
                guard !handledInitialLaunch else { return }
                handledInitialLaunch = true
                await Task.yield()
                composerIsFocused = true
                if let initialQuestion {
                    requestChatAction(.initialQuestion(initialQuestion))
                }
            }
            .sheet(isPresented: $showingCloudAIConsent) {
                CloudAIConsentView(
                    onAllow: {
                        runPendingChatAction()
                    },
                    onUsePrivate: {
                        viewModel.selectedMode = .onDevice
                        runPendingChatAction()
                    }
                )
                .environment(themeManager)
            }
        }
    }

    private func modeSelector(viewModel: Bindable<TranscriptChatViewModel>, t: AppTheme) -> some View {
        VStack(alignment: .leading, spacing: t.spacing.s) {
            Picker("Chat mode", selection: viewModel.selectedMode) {
                ForEach(TranscriptChatMode.allCases) { mode in
                    Label(mode.displayName, systemImage: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(self.viewModel.isResponding)

            HStack(alignment: .top, spacing: t.spacing.s) {
                Image(systemName: self.viewModel.selectedMode.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(self.viewModel.selectedMode == .onDevice
                        ? t.colors.accentSuccess
                        : t.colors.accentPrimary)
                    .padding(.top, 2)
                Text(self.viewModel.selectedMode.disclosure)
                    .font(t.typography.caption)
                    .foregroundStyle(t.colors.textSecondary)
            }

            if let issue = self.viewModel.error ?? self.viewModel.blockingError {
                issueBanner(issue, t: t)
            }
        }
        .padding(.horizontal, t.spacing.l)
        .padding(.vertical, t.spacing.m)
        .background(t.colors.backgroundSecondary)
    }

    private func conversation(_ t: AppTheme) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: t.spacing.m) {
                    if viewModel.messages.isEmpty {
                        emptyConversation(t)
                    } else {
                        ForEach(viewModel.messages) { message in
                            messageBubble(message, t: t)
                                .id(message.id)
                        }
                    }

                    if viewModel.isResponding {
                        thinkingRow(t)
                            .id("thinking")
                    }
                }
                .padding(t.spacing.l)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: viewModel.messages.count) { _, _ in
                withAnimation { proxy.scrollTo(viewModel.messages.last?.id, anchor: .bottom) }
            }
            .onChange(of: viewModel.isResponding) { _, responding in
                if responding {
                    withAnimation { proxy.scrollTo("thinking", anchor: .bottom) }
                }
            }
        }
    }

    private func emptyConversation(_ t: AppTheme) -> some View {
        VStack(spacing: t.spacing.l) {
            VStack(spacing: t.spacing.s) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 32))
                    .foregroundStyle(t.colors.accentPrimary)
                Text("Chat with this meeting")
                    .font(t.typography.headlineMedium)
                    .foregroundStyle(t.colors.textPrimary)
                Text("Ask for details, next steps, a draft, or candid advice. Answers about the meeting will cite transcript timestamps.")
                    .font(t.typography.bodySmall)
                    .foregroundStyle(t.colors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: t.spacing.s) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        requestChatAction(.suggestion(suggestion))
                    } label: {
                        HStack {
                            Text(suggestion)
                                .font(t.typography.bodySmall)
                                .foregroundStyle(t.colors.textPrimary)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(t.colors.accentPrimary)
                        }
                        .padding(t.spacing.m)
                        .background(t.colors.surfacePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: t.radius.m))
                        .overlay {
                            RoundedRectangle(cornerRadius: t.radius.m)
                                .strokeBorder(t.colors.border, lineWidth: 1)
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(viewModel.blockingError != nil)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, t.spacing.xl)
    }

    private func messageBubble(_ message: TranscriptChatMessage, t: AppTheme) -> some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: t.spacing.xs) {
            if message.role == .assistant, let mode = message.mode {
                Label(mode == .onDevice ? "On-device" : "Claude", systemImage: mode.icon)
                    .font(t.typography.labelSmall)
                    .foregroundStyle(t.colors.textTertiary)
            }

            Group {
                if message.role == .assistant {
                    MarkdownMessageView(markdown: message.text, theme: t)
                } else {
                    Text(message.text)
                }
            }
            .font(t.typography.bodyMedium)
            .foregroundStyle(message.role == .user ? t.colors.textOnAccent : t.colors.textPrimary)
            .lineSpacing(3)
            .padding(.horizontal, t.spacing.m)
            .padding(.vertical, t.spacing.m)
            .background(message.role == .user ? t.colors.accentPrimary : t.colors.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: t.radius.l))

            if message.role == .assistant {
                Button {
                    copyResponse(message)
                } label: {
                    Label(
                        copiedMessageID == message.id ? "Copied" : "Copy",
                        systemImage: copiedMessageID == message.id ? "checkmark" : "doc.on.doc"
                    )
                    .font(t.typography.labelSmall)
                    .foregroundStyle(
                        copiedMessageID == message.id
                            ? t.colors.accentSuccess
                            : t.colors.textTertiary
                    )
                    .padding(.horizontal, t.spacing.s)
                    .padding(.vertical, t.spacing.xs)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copiedMessageID == message.id ? "Response copied" : "Copy response")
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .padding(message.role == .user ? .leading : .trailing, t.spacing.huge)
    }

    private func thinkingRow(_ t: AppTheme) -> some View {
        HStack(spacing: t.spacing.s) {
            ProgressView().controlSize(.small).tint(t.colors.accentPrimary)
            Text(viewModel.selectedMode == .onDevice ? "Thinking on device…" : "Asking Claude…")
                .font(t.typography.bodySmall)
                .foregroundStyle(t.colors.textSecondary)
            Spacer()
        }
        .padding(t.spacing.m)
        .background(t.colors.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: t.radius.l))
        .padding(.trailing, t.spacing.huge)
    }

    private func composer(_ t: AppTheme) -> some View {
        VStack(spacing: t.spacing.s) {
            if viewModel.hasPendingQuestion, !viewModel.isResponding {
                HStack {
                    Text("This question still needs an answer.")
                        .font(t.typography.caption)
                        .foregroundStyle(t.colors.textSecondary)
                    Spacer()
                    Button("Retry") { requestChatAction(.retry) }
                        .font(t.typography.labelLarge)
                        .foregroundStyle(t.colors.accentPrimary)
                        .disabled(viewModel.blockingError != nil)
                }
            }

            HStack(alignment: .bottom, spacing: t.spacing.s) {
                TextField("Ask about this meeting…", text: $viewModel.draft, axis: .vertical)
                    .lineLimit(1...5)
                    .font(t.typography.bodyMedium)
                    .foregroundStyle(t.colors.textPrimary)
                    .padding(.horizontal, t.spacing.m)
                    .padding(.vertical, 10)
                    .background(t.colors.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: t.radius.l))
                    .overlay {
                        RoundedRectangle(cornerRadius: t.radius.l)
                            .strokeBorder(t.colors.border, lineWidth: 1)
                    }
                    .focused($composerIsFocused)
                    .defaultFocus($composerIsFocused, true)
                    .onSubmit { requestChatAction(.send) }

                Button {
                    requestChatAction(.send)
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(viewModel.canSend ? t.colors.textOnAccent : t.colors.textTertiary)
                        .frame(width: 42, height: 42)
                        .background(viewModel.canSend ? t.colors.accentPrimary : t.colors.surfaceSecondary)
                        .clipShape(Circle())
                }
                .disabled(!viewModel.canSend)
            }
        }
        .padding(.horizontal, t.spacing.l)
        .padding(.vertical, t.spacing.m)
        .background(t.colors.backgroundSecondary)
    }

    private func issueBanner(_ issue: TranscriptChatError, t: AppTheme) -> some View {
        VStack(alignment: .leading, spacing: t.spacing.s) {
            HStack(alignment: .top, spacing: t.spacing.s) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(t.colors.accentWarning)
                    .padding(.top, 2)
                Text(issue.localizedDescription)
                    .font(t.typography.caption)
                    .foregroundStyle(t.colors.textSecondary)
            }

            if issue.offersBestQuality {
                if viewModel.hasAnthropicKey {
                    Button("Use Best Quality") {
                        viewModel.selectedMode = .bestQuality
                        requestChatAction(.retry)
                    }
                    .font(t.typography.labelLarge)
                    .foregroundStyle(t.colors.accentPrimary)
                } else {
                    Text("Best Quality will be available when Momentus Cloud is online.")
                        .font(t.typography.caption)
                        .foregroundStyle(t.colors.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(t.spacing.m)
        .background(t.colors.accentWarning.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: t.radius.m))
    }

    private func requestChatAction(_ action: PendingChatAction) {
        if viewModel.selectedMode == .bestQuality, !CloudAIConsent.isGranted {
            pendingChatAction = action
            showingCloudAIConsent = true
        } else {
            runChatAction(action)
        }
    }

    private func runPendingChatAction() {
        guard let action = pendingChatAction else { return }
        pendingChatAction = nil
        runChatAction(action)
    }

    private func runChatAction(_ action: PendingChatAction) {
        Task {
            switch action {
            case .send:
                await viewModel.send()
            case .initialQuestion(let question):
                await viewModel.sendInitialQuestion(question)
            case .suggestion(let suggestion):
                await viewModel.askSuggestion(suggestion)
            case .retry:
                await viewModel.retryPendingQuestion()
            }
        }
    }

    private func copyResponse(_ message: TranscriptChatMessage) {
        UIPasteboard.general.string = message.text
        copiedMessageID = message.id

        Task {
            try? await Task.sleep(for: .seconds(2))
            guard copiedMessageID == message.id else { return }
            copiedMessageID = nil
        }
    }
}

#Preview {
    TranscriptChatView(recording: MockMeetings.sampleRecordings[0])
        .environment(ThemeManager())
        .preferredColorScheme(.dark)
}
