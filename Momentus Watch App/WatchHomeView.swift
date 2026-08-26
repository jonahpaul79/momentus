import SwiftUI

struct WatchHomeView: View {
    @State private var vm = WatchViewModel()
    @State private var showingCloudAIConsent = false
    private let t = WatchTheme.midnightIndigo

    var body: some View {
        NavigationStack {
            switch vm.recordingState {
            case .idle:
                idleView
            case .recording, .paused:
                WatchActiveRecordingView(vm: vm)
            case .processing, .saved:
                WatchSavedView(vm: vm)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .autoStartRecording)) { _ in
            _ = WatchQuickRecordLaunchRequest.consumePendingStart()
            guard vm.recordingState == .idle else { return }
            requestRecordingStart()
        }
        .task {
            if WatchQuickRecordLaunchRequest.consumePendingStart(), vm.recordingState == .idle {
                requestRecordingStart()
            }
        }
        .alert("Allow Cloud AI Processing?", isPresented: $showingCloudAIConsent) {
            Button("Cancel", role: .cancel) {}
            Button("Allow") {
                vm.grantCloudAIConsent()
                Task { await vm.startRecording() }
            }
        } message: {
            Text("Momentus sends audio through Supabase to AssemblyAI for transcription, then sends the transcript and meeting details to Anthropic's Claude. AssemblyAI may use submitted data to improve its models.")
        }
    }

    // MARK: - Idle View

    private var idleView: some View {
        VStack(spacing: 12) {
            // Mode pill
            modePill

            // Record button
            Button {
                requestRecordingStart()
            } label: {
                ZStack {
                    Circle()
                        .fill(t.accentPrimary.opacity(0.15))
                        .frame(width: 90, height: 90)

                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [t.accentPrimary, t.accentPrimary.opacity(0.7)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 68, height: 68)
                        .shadow(color: t.accentPrimary.opacity(0.5), radius: 12)

                    VStack(spacing: 2) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white)
                        Text("Record")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
            .buttonStyle(PlainButtonStyle())

            micTargetIndicator
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private func requestRecordingStart() {
        guard vm.recordingState == .idle else { return }
        if WatchCloudAIConsent.isGranted {
            Task { await vm.startRecording() }
        } else {
            showingCloudAIConsent = true
        }
    }

    private var modePill: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
                .font(.system(size: 10))
            Text("Best Quality")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(t.textPrimary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(t.surfacePrimary)
        .clipShape(Capsule())
    }

    private var micTargetIndicator: some View {
        HStack(spacing: 5) {
            Image(systemName: "applewatch")
                .font(.system(size: 11))
            Text("Recording on Watch")
                .font(.system(size: 11))
        }
        .foregroundStyle(t.textSecondary)
    }
}

#Preview {
    WatchHomeView()
        .preferredColorScheme(.dark)
}
