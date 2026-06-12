import SwiftUI

struct WatchSavedView: View {
    @Bindable var vm: WatchViewModel
    private let t = WatchTheme.midnightIndigo

    var body: some View {
        VStack(spacing: 10) {
            if vm.recordingState == .processing {
                processingView
            } else {
                savedView
            }
        }
        .navigationBarBackButtonHidden(true)
    }

    // MARK: - Processing

    private var processingView: some View {
        let phase = processingPhase(for: vm.processingStatus)
        return ScrollView(.vertical) {
            VStack(spacing: 7) {
                ZStack {
                    Circle()
                        .fill(phase.color.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: phase.icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(phase.color)
                        .symbolEffect(.pulse)
                }

                Text(phase.label)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(t.textPrimary)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.4), value: phase.label)

                if let detail = phase.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(t.textTertiary)
                        .multilineTextAlignment(.center)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                if let message = vm.processingErrorMessage {
                    Text(message)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(t.textPrimary)
                        .multilineTextAlignment(.center)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                }

                failureActions(for: vm.processingStatus)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
            .padding(.bottom, 14)
        }
        .animation(.easeInOut(duration: 0.25), value: vm.processingStatus)
    }

    private struct ProcessingPhase {
        let icon: String
        let label: String
        let detail: String?
        let color: Color
    }

    private func processingPhase(for status: WatchProcessingStatus) -> ProcessingPhase {
        switch status {
        case .checkingProvider:
            return ProcessingPhase(
                icon: "key.fill",
                label: "Checking settings",
                detail: "Using iPhone or iCloud",
                color: t.accentPrimary
            )
        case .checkingPhone:
            return ProcessingPhase(
                icon: "iphone.gen3.radiowaves.left.and.right",
                label: "Checking iPhone",
                detail: nil,
                color: t.accentPrimary
            )
        case .sending:
            return ProcessingPhase(
                icon: "antenna.radiowaves.left.and.right",
                label: "Handing off",
                detail: "Momentus is open on iPhone",
                color: t.accentPrimary
            )
        case .received:
            return ProcessingPhase(
                icon: "iphone",
                label: "Waiting for processing",
                detail: "Keep Momentus open on iPhone",
                color: t.accentPrimary
            )
        case .processingOnPhone:
            return ProcessingPhase(
                icon: "iphone",
                label: "Processing on iPhone",
                detail: "You can keep using your Watch",
                color: t.accentPrimary
            )
        case .uploadingCloud:
            return ProcessingPhase(
                icon: "icloud.and.arrow.up",
                label: "Uploading securely",
                detail: "Using AssemblyAI",
                color: t.accentPrimary
            )
        case .transcribingCloud:
            return ProcessingPhase(
                icon: "waveform.badge.mic",
                label: "Transcribing",
                detail: "Using AssemblyAI",
                color: t.accentPrimary
            )
        case .summarizingCloud:
            return ProcessingPhase(
                icon: "sparkles",
                label: "Summarizing",
                detail: "Using AssemblyAI",
                color: t.accentPrimary
            )
        case .readyToSync:
            return ProcessingPhase(
                icon: "checkmark.circle.fill",
                label: "Notes ready",
                detail: "Sent to iPhone",
                color: t.accentSuccess
            )
        case .needsPhoneWake:
            return ProcessingPhase(
                icon: "iphone.gen3.radiowaves.left.and.right",
                label: "Open Momentus",
                detail: "On your iPhone",
                color: t.accentRecording
            )
        case .needsCloudConfig:
            return ProcessingPhase(
                icon: "key.slash",
                label: "Open Momentus",
                detail: "Sync provider settings",
                color: t.accentRecording
            )
        case .providerFailed:
            return ProcessingPhase(
                icon: "exclamationmark.triangle.fill",
                label: "Provider failed",
                detail: "Retry or record another",
                color: t.accentRecording
            )
        case .failed:
            return ProcessingPhase(
                icon: "exclamationmark.triangle.fill",
                label: "Could not process",
                detail: "Retry or record another",
                color: t.accentRecording
            )
        }
    }

    @ViewBuilder
    private func failureActions(for status: WatchProcessingStatus) -> some View {
        switch status {
        case .needsCloudConfig:
            VStack(spacing: 6) {
                compactActionButton(
                    title: "Sync settings",
                    systemImage: "arrow.clockwise.icloud",
                    isPrimary: true
                ) {
                    Task { await vm.requestProviderSettingsSync() }
                }

                compactActionButton(
                    title: "Record another",
                    systemImage: "mic.fill",
                    isPrimary: false
                ) {
                    vm.recordAnother()
                }
            }

        case .providerFailed, .failed:
            VStack(spacing: 6) {
                compactActionButton(
                    title: "Retry",
                    systemImage: "arrow.clockwise",
                    isPrimary: true
                ) {
                    Task { await vm.retryProcessing() }
                }

                compactActionButton(
                    title: "Record another",
                    systemImage: "mic.fill",
                    isPrimary: false
                ) {
                    vm.recordAnother()
                }
            }

        default:
            EmptyView()
        }
    }

    private func compactActionButton(
        title: String,
        systemImage: String,
        isPrimary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isPrimary ? .white : t.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(isPrimary ? t.accentPrimary : t.surfacePrimary)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - Saved

    private var savedView: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(t.accentSuccess.opacity(0.15))
                    .frame(width: 56, height: 56)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(t.accentSuccess)
            }

            VStack(spacing: 3) {
                Text("Saved")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(t.textPrimary)
                Text("Saved to iCloud")
                    .font(.system(size: 11))
                    .foregroundStyle(t.textSecondary)
            }

            Button("Record another") {
                vm.recordAnother()
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(t.accentPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(t.accentPrimary.opacity(0.15))
            .clipShape(Capsule())
            .buttonStyle(PlainButtonStyle())
        }
    }
}

// MARK: - Complication placeholder
// TODO: Implement WatchKit Complications for Live Activity recording state
// Use CLKComplicationServer + CLKComplicationDataSource
// Show: recording duration when active, last recording time when idle
// Entry point: app intent or WCSession message triggers complication update

#Preview("Processing — early") {
    let vm = WatchViewModel()
    vm.recordingState = .processing
    vm.processingElapsed = 5
    return WatchSavedView(vm: vm)
        .preferredColorScheme(.dark)
}

#Preview("Processing — transcribing") {
    let vm = WatchViewModel()
    vm.recordingState = .processing
    vm.processingElapsed = 45
    return WatchSavedView(vm: vm)
        .preferredColorScheme(.dark)
}

#Preview("Processing — long meeting") {
    let vm = WatchViewModel()
    vm.recordingState = .processing
    vm.processingElapsed = 120
    return WatchSavedView(vm: vm)
        .preferredColorScheme(.dark)
}
