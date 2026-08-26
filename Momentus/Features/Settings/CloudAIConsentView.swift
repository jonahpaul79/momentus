import SwiftUI

struct CloudAIConsentView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss

    let onAllow: () -> Void
    let onUsePrivate: () -> Void

    var body: some View {
        let t = themeManager.currentTheme

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: t.spacing.l) {
                    VStack(alignment: .leading, spacing: t.spacing.s) {
                        Image(systemName: "cloud.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(t.colors.accentPrimary)
                        Text("Allow Cloud AI processing?")
                            .font(t.typography.headlineLarge)
                            .foregroundStyle(t.colors.textPrimary)
                        Text("Best Quality and Hybrid use cloud AI. Private stays on this device.")
                            .font(t.typography.bodyMedium)
                            .foregroundStyle(t.colors.textSecondary)
                    }

                    Text("Best Quality sends audio to **AssemblyAI** for transcription. Best Quality and Hybrid send transcripts and meeting details to **Anthropic (Claude)** for summaries and Ask Momentus, including web search.")
                        .font(t.typography.bodyMedium)
                        .foregroundStyle(t.colors.textPrimary)

                    Text("Momentus securely routes requests and temporarily stages Best Quality audio in its cloud. AssemblyAI's standard terms may permit service or model improvement.")
                        .font(t.typography.bodySmall)
                        .foregroundStyle(t.colors.textSecondary)

                    Link("See exactly what's shared", destination: URL(string: "https://momentusnotes.com/ai-data")!)
                        .font(t.typography.labelLarge)
                        .foregroundStyle(t.colors.accentPrimary)

                    VStack(spacing: t.spacing.s) {
                        Button {
                            CloudAIConsent.grant()
                            onAllow()
                            dismiss()
                        } label: {
                            Text("Allow Cloud AI")
                                .font(t.typography.labelLarge)
                                .foregroundStyle(t.colors.textOnAccent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, t.spacing.m)
                                .background(t.colors.accentPrimary)
                                .clipShape(RoundedRectangle(cornerRadius: t.radius.m))
                        }

                        Button {
                            onUsePrivate()
                            dismiss()
                        } label: {
                            Text("Use Private Mode")
                                .font(t.typography.labelLarge)
                                .foregroundStyle(t.colors.textPrimary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, t.spacing.m)
                                .background(t.colors.surfaceSecondary)
                                .clipShape(RoundedRectangle(cornerRadius: t.radius.m))
                        }
                    }
                }
                .padding(t.spacing.l)
            }
            .background(t.colors.backgroundPrimary)
            .navigationTitle("Cloud AI Permission")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled()
    }
}
