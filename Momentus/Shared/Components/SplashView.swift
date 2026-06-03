import SwiftUI

struct SplashView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Binding var isVisible: Bool
    @State private var opacity: Double = 1

    var body: some View {
        let t = themeManager.currentTheme
        ZStack {
            t.colors.backgroundPrimary
                .ignoresSafeArea()
            VStack(spacing: 20) {
                Image("AppIcon")
                    .resizable()
                    .frame(width: 100, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: t.colors.accentPrimary.opacity(0.3), radius: 20, y: 8)
                Text("Momentus")
                    .font(t.typography.headlineLarge)
                    .foregroundStyle(t.colors.textPrimary)
            }
        }
        .opacity(opacity)
        .allowsHitTesting(opacity > 0)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
                withAnimation(.easeOut(duration: 0.45)) {
                    opacity = 0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    isVisible = false
                }
            }
        }
    }
}
