import SwiftUI
import WidgetKit

enum QuickRecordWidgetStatus {
    nonisolated static let iPhoneWidgetKind = "MomentusQuickRecord"

    nonisolated static func isIPhoneWidgetInstalled() async -> Bool {
        await withCheckedContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { result in
                let isInstalled = (try? result.get())?.contains {
                    $0.kind == iPhoneWidgetKind
                } ?? false
                continuation.resume(returning: isInstalled)
            }
        }
    }
}

struct WidgetEducationView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss

    let iPhoneWidgetInstalled: Bool

    var body: some View {
        let t = themeManager.currentTheme

        NavigationStack {
            ScrollView(.vertical) {
                VStack(spacing: t.spacing.xl) {
                    hero(t)
                    iPhoneSetup(t)
                    watchSetup(t)
                }
                .padding(.horizontal, t.spacing.l)
                .padding(.top, t.spacing.l)
                .padding(.bottom, t.spacing.huge)
            }
            .background(t.colors.backgroundPrimary)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button {
                    dismiss()
                } label: {
                    Text("Got it")
                        .font(t.typography.labelLarge)
                        .foregroundStyle(t.colors.textOnAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, t.spacing.m)
                        .background(t.colors.accentPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: t.radius.l))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, t.spacing.l)
                .padding(.vertical, t.spacing.m)
                .background(.ultraThinMaterial)
            }
            .navigationTitle("Quick Record")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Maybe later") { dismiss() }
                        .foregroundStyle(t.colors.textSecondary)
                }
            }
        }
    }

    private func hero(_ t: AppTheme) -> some View {
        VStack(spacing: t.spacing.l) {
            HStack(spacing: t.spacing.l) {
                widgetPreview(t)
                watchPreview(t)
            }

            VStack(spacing: t.spacing.s) {
                Text("Record in one tap")
                    .font(t.typography.headlineLarge)
                    .foregroundStyle(t.colors.textPrimary)
                    .multilineTextAlignment(.center)
                Text("Start a Momentus recording from your Home Screen, Lock Screen, or Apple Watch—without finding and opening the app first.")
                    .font(t.typography.bodySmall)
                    .foregroundStyle(t.colors.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, t.spacing.m)
    }

    private func widgetPreview(_ t: AppTheme) -> some View {
        VStack(spacing: t.spacing.s) {
            ZStack {
                RoundedRectangle(cornerRadius: t.radius.xl)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.08, green: 0.07, blue: 0.18),
                                Color(red: 0.20, green: 0.12, blue: 0.42)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                VStack(spacing: t.spacing.s) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(Color.indigo)
                        .clipShape(Circle())
                    Text("Record")
                        .font(t.typography.headlineSmall)
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 118, height: 118)
            Text("iPhone")
                .font(t.typography.caption)
                .foregroundStyle(t.colors.textSecondary)
        }
    }

    private func watchPreview(_ t: AppTheme) -> some View {
        VStack(spacing: t.spacing.s) {
            ZStack {
                RoundedRectangle(cornerRadius: 32)
                    .fill(t.colors.surfaceSecondary)
                    .frame(width: 92, height: 112)
                    .overlay {
                        RoundedRectangle(cornerRadius: 32)
                            .strokeBorder(t.colors.border, lineWidth: 2)
                    }
                Circle()
                    .fill(t.colors.accentPrimary.opacity(0.20))
                    .frame(width: 54, height: 54)
                Image(systemName: "mic.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(t.colors.accentPrimary)
            }
            .frame(width: 118, height: 118)
            Text("Apple Watch")
                .font(t.typography.caption)
                .foregroundStyle(t.colors.textSecondary)
        }
    }

    private func iPhoneSetup(_ t: AppTheme) -> some View {
        setupCard(
            icon: "iphone",
            title: "Add it on iPhone",
            status: iPhoneWidgetInstalled ? "Installed" : nil,
            t: t
        ) {
            if iPhoneWidgetInstalled {
                installedMessage(t)
            } else {
                VStack(alignment: .leading, spacing: t.spacing.m) {
                    instruction(1, "Go to your Home Screen and touch and hold the Momentus app icon.", t: t)
                    instruction(2, "Tap the small widget layout shown in the app-icon menu.", t: t)
                    instruction(3, "Move Quick Record where you want it, then tap Done.", t: t)
                }
            }

            Divider().overlay(t.colors.divider)

            VStack(alignment: .leading, spacing: t.spacing.s) {
                Label("Lock Screen", systemImage: "lock.rectangle")
                    .font(t.typography.labelLarge)
                    .foregroundStyle(t.colors.textPrimary)
                Text("Touch and hold your Lock Screen → Customize → Lock Screen → Add Widgets → Momentus.")
                    .font(t.typography.bodySmall)
                    .foregroundStyle(t.colors.textSecondary)
            }
        }
    }

    private func watchSetup(_ t: AppTheme) -> some View {
        setupCard(icon: "applewatch", title: "Add it on Apple Watch", t: t) {
            VStack(alignment: .leading, spacing: t.spacing.m) {
                instruction(1, "Touch and hold your watch face, then tap Edit.", t: t)
                instruction(2, "Swipe to Complications and tap the position you want to change.", t: t)
                instruction(3, "Choose Momentus Quick Record, then press the Digital Crown.", t: t)
            }

            Divider().overlay(t.colors.divider)

            VStack(alignment: .leading, spacing: t.spacing.s) {
                Label("Smart Stack", systemImage: "rectangle.stack")
                    .font(t.typography.labelLarge)
                    .foregroundStyle(t.colors.textPrimary)
                Text("Open the Smart Stack → scroll to the bottom → Edit → Add Widget → Momentus. Pin it to keep Quick Record easy to reach.")
                    .font(t.typography.bodySmall)
                    .foregroundStyle(t.colors.textSecondary)
            }
        }
    }

    private func installedMessage(_ t: AppTheme) -> some View {
        HStack(alignment: .top, spacing: t.spacing.s) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(t.colors.accentSuccess)
            Text("Quick Record is already configured on this iPhone. You can still add another size or place it on your Lock Screen.")
                .font(t.typography.bodySmall)
                .foregroundStyle(t.colors.textSecondary)
        }
    }

    private func setupCard<Content: View>(
        icon: String,
        title: String,
        status: String? = nil,
        t: AppTheme,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: t.spacing.l) {
            HStack(spacing: t.spacing.s) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(t.colors.accentPrimary)
                    .frame(width: 34, height: 34)
                    .background(t.colors.accentPrimary.opacity(0.12))
                    .clipShape(Circle())
                Text(title)
                    .font(t.typography.headlineMedium)
                    .foregroundStyle(t.colors.textPrimary)
                Spacer()
                if let status {
                    Label(status, systemImage: "checkmark")
                        .font(t.typography.caption)
                        .foregroundStyle(t.colors.accentSuccess)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(t.spacing.l)
        .background(t.colors.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: t.radius.l))
        .overlay {
            RoundedRectangle(cornerRadius: t.radius.l)
                .strokeBorder(t.colors.border, lineWidth: 1)
        }
    }

    private func instruction(_ number: Int, _ text: String, t: AppTheme) -> some View {
        HStack(alignment: .top, spacing: t.spacing.m) {
            Text("\(number)")
                .font(t.typography.labelLarge)
                .foregroundStyle(t.colors.textOnAccent)
                .frame(width: 24, height: 24)
                .background(t.colors.accentPrimary)
                .clipShape(Circle())
            Text(text)
                .font(t.typography.bodySmall)
                .foregroundStyle(t.colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    WidgetEducationView(iPhoneWidgetInstalled: false)
        .environment(ThemeManager())
        .preferredColorScheme(.dark)
}
