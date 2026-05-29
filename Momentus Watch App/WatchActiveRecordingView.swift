import SwiftUI

struct WatchActiveRecordingView: View {
    @Bindable var vm: WatchViewModel
    private let t = WatchTheme.midnightIndigo

    var body: some View {
        VStack(spacing: 8) {
            // Status row
            HStack {
                HStack(spacing: 4) {
                    Circle()
                        .fill(vm.recordingState == .paused ? t.accentSuccess : t.accentRecording)
                        .frame(width: 6, height: 6)
                    Text(vm.recordingState == .paused ? "Paused" : "REC")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(t.textPrimary)
                }
                Spacer()
                Text(vm.selectedMode.rawValue)
                    .font(.system(size: 10))
                    .foregroundStyle(t.textSecondary)
            }

            // Timer
            Text(vm.elapsedTime.timerString)
                .font(.system(size: 32, weight: .thin, design: .monospaced))
                .foregroundStyle(t.textPrimary)
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: false))

            // Waveform
            WatchWaveformView(
                levels: vm.recordingState == .recording ? vm.waveformLevels : Array(repeating: 0.05, count: 16),
                color: vm.recordingState == .recording ? t.accentRecording.opacity(0.8) : t.textSecondary.opacity(0.3)
            )
            .frame(height: 22)

            // Controls
            HStack(spacing: 12) {
                // Pause / Resume
                Button {
                    Task {
                        if vm.recordingState == .paused {
                            vm.recordingState = .recording
                        } else {
                            await vm.pauseRecording()
                        }
                    }
                } label: {
                    Image(systemName: vm.recordingState == .paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(t.textPrimary)
                        .frame(width: 40, height: 40)
                        .background(t.surfacePrimary)
                        .clipShape(Circle())
                }
                .buttonStyle(PlainButtonStyle())

                // Stop
                Button {
                    Task { await vm.stopRecording() }
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(t.accentRecording)
                        .clipShape(Circle())
                        .shadow(color: t.accentRecording.opacity(0.5), radius: 8)
                }
                .buttonStyle(PlainButtonStyle())

                // Marker
                Button {
                    vm.addMarker()
                } label: {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(t.textPrimary)
                        .frame(width: 40, height: 40)
                        .background(t.surfacePrimary)
                        .clipShape(Circle())
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 8)
        .navigationBarBackButtonHidden(true)
    }
}

#Preview {
    let vm = WatchViewModel()
    return WatchActiveRecordingView(vm: vm)
        .preferredColorScheme(.dark)
}
