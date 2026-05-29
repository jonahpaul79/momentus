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
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(t.accentPrimary.opacity(0.15))
                    .frame(width: 56, height: 56)
                ProgressView()
                    .tint(t.accentPrimary)
                    .scaleEffect(1.2)
            }
            Text("Processing")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(t.textPrimary)
            Text("Processing on iPhone")
                .font(.system(size: 11))
                .foregroundStyle(t.textSecondary)
                .multilineTextAlignment(.center)
        }
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
                Text("Notes ready on iPhone")
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

#Preview("Processing") {
    let vm = WatchViewModel()
    return WatchSavedView(vm: vm)
        .preferredColorScheme(.dark)
}
