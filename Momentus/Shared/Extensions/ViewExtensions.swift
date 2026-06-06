import SwiftUI

// MARK: - Surface Card

struct SurfaceCardModifier: ViewModifier {
    @Environment(ThemeManager.self) private var themeManager
    var elevated: Bool = false

    func body(content: Content) -> some View {
        let t = themeManager.currentTheme
        content
            .background(elevated ? t.colors.surfaceSecondary : t.colors.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: t.radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: t.radius.card)
                    .strokeBorder(t.colors.border, lineWidth: 0.5)
            )
            .shadow(
                color: t.shadows.card.color,
                radius: t.shadows.card.radius,
                x: t.shadows.card.x,
                y: t.shadows.card.y
            )
    }
}

extension View {
    func surfaceCard(elevated: Bool = false) -> some View {
        modifier(SurfaceCardModifier(elevated: elevated))
    }
}

// MARK: - Mode Badge

struct ModeBadge: View {
    @Environment(ThemeManager.self) private var themeManager
    let mode: RecordingMode
    var compact: Bool = false

    var body: some View {
        let t = themeManager.currentTheme
        HStack(spacing: 4) {
            Image(systemName: mode.icon)
                .font(.system(size: compact ? 14 : 11, weight: .semibold))
            if !compact {
                Text(mode.shortName)
                    .font(t.typography.labelLarge)
            }
        }
        .foregroundStyle(modeColor(t))
        .padding(.horizontal, compact ? 10 : 8)
        .padding(.vertical, compact ? 6 : 4)
        .background(modeColor(t).opacity(0.15))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(modeColor(t).opacity(0.30), lineWidth: 0.5))
    }

    private func modeColor(_ t: AppTheme) -> Color {
        switch mode {
        case .onDevice: return t.colors.accentSuccess
        case .bestQuality: return t.colors.accentPrimary
        case .hybrid: return t.colors.accentSecondary
        }
    }
}

// MARK: - Confidence Badge

struct ConfidenceBadge: View {
    @Environment(ThemeManager.self) private var themeManager
    let label: String
    var isWarning: Bool = false

    var body: some View {
        let t = themeManager.currentTheme
        Text(label)
            .font(t.typography.labelSmall)
            .foregroundStyle(isWarning ? t.colors.accentWarning : t.colors.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background((isWarning ? t.colors.accentWarning : t.colors.textSecondary).opacity(0.12))
            .clipShape(Capsule())
    }
}

// MARK: - Duration Formatter

extension TimeInterval {
    var timerString: String {
        let h = Int(self) / 3600
        let m = (Int(self) % 3600) / 60
        let s = Int(self) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    var shortString: String {
        let m = Int(self) / 60
        let h = m / 60
        if h > 0 { return "\(h)h \(m % 60)m" }
        if m > 0 { return "\(m)m" }
        return "<1m"
    }
}

// MARK: - Date Formatters

extension Date {
    func relativeLabel() -> String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return "Today" }
        if cal.isDateInYesterday(self) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: self)
    }

    func timeString() -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: self)
    }
}

// MARK: - Haptic Helpers

enum HapticStyle {
    case light, medium, heavy, success, warning, error

    func trigger() {
        switch self {
        case .light: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .medium: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .heavy: UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning: UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .error: UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

// MARK: - View Utilities

extension View {
    func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
