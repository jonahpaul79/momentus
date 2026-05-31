import SwiftUI

struct ActiveRecordingView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Bindable var vm: RecordViewModel
    var onStop: () -> Void

    var body: some View {
        let t = themeManager.currentTheme
        ZStack {
            t.gradients.activeRecording
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar(t)
                Spacer()
                recordingOrb(t)
                timerDisplay(t)
                Spacer()
                waveformSection(t)
                controlBar(t)
            }
        }
    }

    // MARK: - Top Bar

    private func topBar(_ t: AppTheme) -> some View {
        HStack {
            HStack(spacing: 6) {
                ModeBadge(mode: vm.selectedMode)
                    .environment(themeManager)

                HStack(spacing: 4) {
                    Image(systemName: vm.selectedMicSource.icon)
                        .font(.system(size: 11))
                    Text(vm.selectedMicSource.shortName)
                        .font(t.typography.labelLarge)
                }
                .foregroundStyle(t.colors.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(t.colors.surfacePrimary.opacity(0.6))
                .clipShape(Capsule())
            }

            Spacer()

            // Recording indicator pill
            HStack(spacing: 5) {
                Circle()
                    .fill(vm.state == .paused ? t.colors.accentWarning : t.colors.accentRecording)
                    .frame(width: 7, height: 7)
                Text(vm.state == .paused ? "Paused" : "Recording")
                    .font(t.typography.labelLarge)
                    .foregroundStyle(t.colors.textPrimary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(t.colors.surfacePrimary.opacity(0.7))
            .clipShape(Capsule())
        }
        .padding(.horizontal, t.spacing.l)
        .padding(.top, t.spacing.xl)
    }

    // MARK: - Recording Orb

    private func recordingOrb(_ t: AppTheme) -> some View {
        Button {
            Task {
                if vm.state == .paused {
                    await vm.resumeRecording()
                } else {
                    await vm.pauseRecording()
                }
            }
        } label: {
            RecordingOrb(
                size: 130,
                color: t.colors.accentRecording,
                isRecording: vm.state == .recording,
                isPaused: vm.state == .paused
            )
        }
        .buttonStyle(PlainButtonStyle())
        .padding(.bottom, t.spacing.xxl)
    }

    // MARK: - Timer

    private func timerDisplay(_ t: AppTheme) -> some View {
        VStack(spacing: t.spacing.xs) {
            Text(vm.elapsedTime.timerString)
                .font(t.typography.timer)
                .foregroundStyle(t.colors.textPrimary)
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: false))

            Text(vm.state == .paused ? "Paused" : "Recording in progress")
                .font(t.typography.bodySmall)
                .foregroundStyle(t.colors.textSecondary)
        }
    }

    // MARK: - Waveform

    private func waveformSection(_ t: AppTheme) -> some View {
        WaveformView(
            levels: vm.state == .recording ? vm.waveformLevels : Array(repeating: 0.05, count: 20),
            color: vm.state == .recording
                ? t.colors.accentPrimary.opacity(0.85)
                : t.colors.textTertiary
        )
        .frame(height: 56)
        .padding(.horizontal, t.spacing.xxl)
        .padding(.bottom, t.spacing.xxxl)
    }

    // MARK: - Control Bar

    private func controlBar(_ t: AppTheme) -> some View {
        VStack(spacing: t.spacing.l) {
            // Main row: pause | STOP | marker
            HStack(spacing: t.spacing.xxxl) {
                // Pause / Resume
                CircleButton(
                    icon: vm.state == .paused ? "play.fill" : "pause.fill",
                    label: vm.state == .paused ? "Resume" : "Pause",
                    color: t.colors.textSecondary,
                    size: 52
                ) {
                    Task {
                        if vm.state == .paused {
                            await vm.resumeRecording()
                        } else {
                            await vm.pauseRecording()
                        }
                    }
                }

                // Stop
                CircleButton(
                    icon: "stop.fill",
                    label: "Stop",
                    color: t.colors.accentRecording,
                    size: 70,
                    filled: true
                ) {
                    onStop()
                    Task { await vm.stopRecording() }
                }

                // Marker
                CircleButton(
                    icon: "bookmark.fill",
                    label: "Marker",
                    color: t.colors.textSecondary,
                    size: 52
                ) {
                    vm.addMarker()
                }
            }

            Text("Tap Marker to flag a moment")
                .font(t.typography.caption)
                .foregroundStyle(t.colors.textTertiary)
        }
        .padding(.horizontal, t.spacing.l)
        .padding(.bottom, t.spacing.huge)
    }
}

// MARK: - Circle Button

struct CircleButton: View {
    @Environment(ThemeManager.self) private var themeManager
    let icon: String
    let label: String
    let color: Color
    var size: CGFloat = 56
    var filled: Bool = false
    let action: () -> Void

    var body: some View {
        let t = themeManager.currentTheme
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(filled ? color : t.colors.surfaceSecondary)
                        .frame(width: size, height: size)
                        .shadow(
                            color: filled ? color.opacity(0.4) : .clear,
                            radius: filled ? 16 : 0
                        )
                    Image(systemName: icon)
                        .font(.system(size: size * 0.32, weight: .medium))
                        .foregroundStyle(filled ? .white : color)
                }
                Text(label)
                    .font(t.typography.caption)
                    .foregroundStyle(t.colors.textSecondary)
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
}

#Preview("Active Recording") {
    let vm = RecordViewModel()
    return ActiveRecordingView(vm: vm, onStop: {})
        .environment(ThemeManager())
        .preferredColorScheme(.dark)
}

#Preview("Paused") {
    let vm = RecordViewModel()
    return ActiveRecordingView(vm: vm, onStop: {})
        .environment(ThemeManager())
        .preferredColorScheme(.dark)
}
