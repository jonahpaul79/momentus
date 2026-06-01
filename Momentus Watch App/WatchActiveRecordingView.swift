import SwiftUI

struct WatchActiveRecordingView: View {
    @Bindable var vm: WatchViewModel
    private let t = WatchTheme.midnightIndigo

    var body: some View {
        GeometryReader { geo in
            let isSmall = geo.size.height < 170
            let stopSize: CGFloat = isSmall ? 44 : 52
            let sideButtonSize: CGFloat = isSmall ? 34 : 40
            let timerFont: CGFloat = isSmall ? 26 : 32
            let waveformHeight: CGFloat = isSmall ? 28 : 36
            let vSpacing: CGFloat = isSmall ? 4 : 8

            VStack(spacing: vSpacing) {
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
                    .font(.system(size: timerFont, weight: .thin, design: .monospaced))
                    .foregroundStyle(t.textPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: false))

                // Waveform
                WatchWaveformView(
                    levels: vm.recordingState == .recording ? vm.waveformLevels : Array(repeating: 0.05, count: 20),
                    color: vm.recordingState == .recording ? t.accentPrimary.opacity(0.8) : t.textSecondary.opacity(0.3),
                    highlightedBars: vm.markerHighlightedBars,
                    highlightColor: t.accentRecording
                )
                .frame(height: waveformHeight)
                .padding(.horizontal, 2)

                // Controls
                HStack(spacing: isSmall ? 8 : 12) {
                    // Pause / Resume
                    Button {
                        Task {
                            if vm.recordingState == .paused {
                                await vm.resumeRecording()
                            } else {
                                await vm.pauseRecording()
                            }
                        }
                    } label: {
                        Image(systemName: vm.recordingState == .paused ? "play.fill" : "pause.fill")
                            .font(.system(size: isSmall ? 13 : 16, weight: .medium))
                            .foregroundStyle(t.textPrimary)
                            .frame(width: sideButtonSize, height: sideButtonSize)
                            .background(t.surfacePrimary)
                            .clipShape(Circle())
                    }
                    .buttonStyle(PlainButtonStyle())

                    // Stop
                    Button {
                        Task { await vm.stopRecording() }
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: isSmall ? 15 : 18, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: stopSize, height: stopSize)
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
                            .font(.system(size: isSmall ? 13 : 16, weight: .medium))
                            .foregroundStyle(t.textPrimary)
                            .frame(width: sideButtonSize, height: sideButtonSize)
                            .background(t.surfacePrimary)
                            .clipShape(Circle())
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 8)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
        .navigationBarBackButtonHidden(true)
    }
}

#Preview {
    let vm = WatchViewModel()
    return WatchActiveRecordingView(vm: vm)
        .preferredColorScheme(.dark)
}
