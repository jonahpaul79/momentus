import SwiftUI

struct WatchHomeView: View {
    @State private var vm = WatchViewModel()
    private let t = WatchTheme.midnightIndigo

    var body: some View {
        NavigationStack {
            switch vm.recordingState {
            case .idle:
                idleView
            case .recording, .paused:
                NavigationLink(destination: WatchActiveRecordingView(vm: vm)) {
                    EmptyView()
                }
                .opacity(0)
                .onAppear { /* auto-push handled below */ }
                WatchActiveRecordingView(vm: vm)
            case .processing, .saved:
                WatchSavedView(vm: vm)
            }
        }
    }

    // MARK: - Idle View

    private var idleView: some View {
        VStack(spacing: 12) {
            // Mode pill
            modePill

            // Record button
            Button {
                Task { await vm.startRecording() }
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
        .navigationTitle("Momentus")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var modePill: some View {
        Button {
            vm.selectedMode = vm.selectedMode == .onDevice ? .bestQuality : .onDevice
        } label: {
            HStack(spacing: 4) {
                Image(systemName: vm.selectedMode == .onDevice ? "lock.shield.fill" : "sparkles")
                    .font(.system(size: 10))
                Text(vm.selectedMode.rawValue)
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
            }
            .foregroundStyle(t.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(t.surfacePrimary)
            .clipShape(Capsule())
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var micTargetIndicator: some View {
        HStack(spacing: 5) {
            Image(systemName: vm.micTarget == .iPhone ? "iphone" : "applewatch")
                .font(.system(size: 11))
            Text(vm.micTarget == .iPhone ? "Recording on iPhone" : "Recording on Watch")
                .font(.system(size: 11))
        }
        .foregroundStyle(t.textSecondary)
    }
}

#Preview {
    WatchHomeView()
        .preferredColorScheme(.dark)
}
