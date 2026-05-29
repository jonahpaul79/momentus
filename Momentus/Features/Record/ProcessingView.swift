import SwiftUI

struct ProcessingView: View {
    @Environment(ThemeManager.self) private var themeManager
    let vm: RecordViewModel
    var onDismiss: () -> Void

    private let steps: [(title: String, subtitle: String, icon: String)] = [
        ("Saving audio", "Securing your recording", "square.and.arrow.down"),
        ("Transcribing", "Converting speech to text", "waveform"),
        ("Summarizing", "Extracting key moments", "sparkles"),
        ("Preparing notes", "Organizing your insights", "doc.text"),
    ]

    var body: some View {
        let t = themeManager.currentTheme
        ZStack {
            t.colors.backgroundPrimary.ignoresSafeArea()

            VStack(spacing: 0) {
                if vm.state == .completed {
                    completedView(t)
                } else {
                    processingView(t)
                }
            }
        }
        .onChange(of: vm.state) { _, newState in
            if case .completed = newState {
                // auto-dismiss after a moment if in full-screen cover
            }
        }
    }

    // MARK: - Processing

    private func processingView(_ t: AppTheme) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                // Header
                VStack(spacing: t.spacing.m) {
                    ZStack {
                        Circle()
                            .fill(t.colors.accentPrimary.opacity(0.12))
                            .frame(width: 80, height: 80)
                        Image(systemName: "waveform.and.magnifyingglass")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(t.colors.accentPrimary)
                    }
                    .padding(.top, t.spacing.huge)

                    Text("Processing your meeting")
                        .font(t.typography.headlineLarge)
                        .foregroundStyle(t.colors.textPrimary)
                        .multilineTextAlignment(.center)

                    Text("You can leave this screen — we'll keep processing when possible.")
                        .font(t.typography.bodyMedium)
                        .foregroundStyle(t.colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, t.spacing.xxxl)
                }
                .padding(.bottom, t.spacing.xxxl)

                // Steps
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        ProcessingStepRow(
                            title: step.title,
                            subtitle: step.subtitle,
                            icon: step.icon,
                            status: stepStatus(for: index)
                        )
                        .environment(themeManager)

                        if index < steps.count - 1 {
                            Rectangle()
                                .fill(t.colors.divider)
                                .frame(width: 1, height: 20)
                                .padding(.leading, 35)
                        }
                    }
                }
                .padding(.horizontal, t.spacing.l)
                .padding(.vertical, t.spacing.l)
                .surfaceCard()
                .environment(themeManager)
                .padding(.horizontal, t.spacing.l)

                // Privacy note (cloud modes)
                if vm.selectedMode.usesCloud {
                    cloudPrivacyNote(t)
                        .padding(.horizontal, t.spacing.l)
                        .padding(.top, t.spacing.l)
                }

                Spacer(minLength: t.spacing.huge)

                Button("Dismiss") { onDismiss() }
                    .font(t.typography.bodyMedium)
                    .foregroundStyle(t.colors.textSecondary)
                    .padding(.bottom, t.spacing.huge)
            }
        }
    }

    private func stepStatus(for index: Int) -> ProcessingStepStatus {
        let current = vm.processingStepIndex
        if index < current { return .completed }
        if index == current { return .active }
        return .pending
    }

    private func cloudPrivacyNote(_ t: AppTheme) -> some View {
        HStack(alignment: .top, spacing: t.spacing.m) {
            Image(systemName: "info.circle")
                .font(.system(size: 14))
                .foregroundStyle(t.colors.textSecondary)
            Text("Audio is sent only to your selected provider and deleted after processing when possible.")
                .font(t.typography.caption)
                .foregroundStyle(t.colors.textSecondary)
        }
        .padding(t.spacing.m)
        .background(t.colors.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: t.radius.m))
        .overlay(RoundedRectangle(cornerRadius: t.radius.m).strokeBorder(t.colors.border, lineWidth: 0.5))
    }

    // MARK: - Completed

    private func completedView(_ t: AppTheme) -> some View {
        VStack(spacing: t.spacing.xl) {
            Spacer()

            ZStack {
                Circle()
                    .fill(t.colors.accentSuccess.opacity(0.15))
                    .frame(width: 100, height: 100)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(t.colors.accentSuccess)
            }

            VStack(spacing: t.spacing.s) {
                Text("Notes ready")
                    .font(t.typography.displayMedium)
                    .foregroundStyle(t.colors.textPrimary)
                Text("Your meeting has been processed.")
                    .font(t.typography.bodyMedium)
                    .foregroundStyle(t.colors.textSecondary)
            }

            Spacer()

            Button {
                HapticStyle.success.trigger()
                onDismiss()
            } label: {
                Text("View notes")
                    .font(t.typography.headlineMedium)
                    .foregroundStyle(t.colors.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, t.spacing.l)
                    .background(t.colors.accentPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: t.radius.l))
            }
            .padding(.horizontal, t.spacing.xxxl)
            .padding(.bottom, t.spacing.huge)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }
}

// MARK: - Processing Step Row

enum ProcessingStepStatus { case pending, active, completed }

struct ProcessingStepRow: View {
    @Environment(ThemeManager.self) private var themeManager
    let title: String
    let subtitle: String
    let icon: String
    let status: ProcessingStepStatus

    @State private var spinAngle = 0.0

    var body: some View {
        let t = themeManager.currentTheme
        HStack(spacing: t.spacing.l) {
            ZStack {
                Circle()
                    .fill(indicatorBackground(t))
                    .frame(width: 36, height: 36)

                switch status {
                case .completed:
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                case .active:
                    Circle()
                        .trim(from: 0, to: 0.72)
                        .stroke(t.colors.accentPrimary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .frame(width: 22, height: 22)
                        .rotationEffect(.degrees(spinAngle))
                        .onAppear {
                            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                                spinAngle = 360
                            }
                        }
                case .pending:
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .foregroundStyle(t.colors.textTertiary)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(t.typography.headlineSmall)
                    .foregroundStyle(textColor(t))
                if status == .active {
                    Text(subtitle)
                        .font(t.typography.caption)
                        .foregroundStyle(t.colors.textSecondary)
                }
            }

            Spacer()
        }
        .padding(.vertical, t.spacing.m)
        .animation(.easeInOut(duration: 0.3), value: status)
    }

    private func indicatorBackground(_ t: AppTheme) -> Color {
        switch status {
        case .completed: return t.colors.accentSuccess
        case .active: return t.colors.surfaceTertiary
        case .pending: return t.colors.surfaceSecondary
        }
    }

    private func textColor(_ t: AppTheme) -> Color {
        switch status {
        case .completed: return t.colors.accentSuccess
        case .active: return t.colors.textPrimary
        case .pending: return t.colors.textTertiary
        }
    }
}

#Preview {
    let vm = RecordViewModel()
    return ProcessingView(vm: vm, onDismiss: {})
        .environment(ThemeManager())
        .preferredColorScheme(.dark)
}
