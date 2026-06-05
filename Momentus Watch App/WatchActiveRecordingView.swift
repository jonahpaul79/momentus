import SwiftUI

struct WatchActiveRecordingView: View {
    @Bindable var vm: WatchViewModel
    private let t = WatchTheme.midnightIndigo

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let w = geo.size.width

            // All sizes are proportional to the available height so the layout
            // always fits, regardless of watch size (40mm SE through 49mm Ultra).
            let stopSize: CGFloat   = min(h * 0.29, w * 0.30)
            let sideSize: CGFloat   = min(h * 0.22, w * 0.23)
            let timerSize: CGFloat  = h * 0.19
            let waveH: CGFloat      = h * 0.25

            VStack(spacing: 0) {
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
                .padding(.bottom, h * 0.02)

                // Timer — shrinks if needed but never wraps
                Text(vm.elapsedTime.timerString)
                    .font(.system(size: timerSize, weight: .thin, design: .monospaced))
                    .foregroundStyle(t.textPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: false))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)

                Spacer(minLength: 0)

                // Waveform
                WatchWaveformView(
                    levels: vm.recordingState == .recording
                        ? vm.waveformLevels
                        : Array(repeating: 0.05, count: 20),
                    color: vm.recordingState == .recording
                        ? t.accentPrimary.opacity(0.8)
                        : t.textSecondary.opacity(0.3),
                    highlightedBars: vm.markerHighlightedBars,
                    highlightColor: t.accentRecording
                )
                .frame(height: waveH)
                .padding(.horizontal, 2)

                Spacer(minLength: 0)

                // Controls — spaced to fill the row width
                let hPad: CGFloat = 8
                let gap = max(6, (w - hPad * 2 - stopSize - sideSize * 2) / 2)
                HStack(spacing: gap) {
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
                            .font(.system(size: sideSize * 0.38, weight: .medium))
                            .foregroundStyle(t.textPrimary)
                            .frame(width: sideSize, height: sideSize)
                            .background(t.surfacePrimary)
                            .clipShape(Circle())
                    }
                    .buttonStyle(PlainButtonStyle())

                    // Stop
                    Button {
                        Task { await vm.stopRecording() }
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: stopSize * 0.35, weight: .medium))
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
                            .font(.system(size: sideSize * 0.38, weight: .medium))
                            .foregroundStyle(t.textPrimary)
                            .frame(width: sideSize, height: sideSize)
                            .background(t.surfacePrimary)
                            .clipShape(Circle())
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.top, h * 0.02)
            }
            .padding(.horizontal, hPad)
            .padding(.vertical, h * 0.03)
            .frame(width: w, height: h, alignment: .center)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
    }
}

#Preview {
    let vm = WatchViewModel()
    return WatchActiveRecordingView(vm: vm)
        .preferredColorScheme(.dark)
}
