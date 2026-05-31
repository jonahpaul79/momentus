import SwiftUI

// MARK: - Color Tokens

/// All color decisions for a theme. Use semantic names, never raw hex values in views.
///
/// Layer hierarchy (darkest → lightest in dark mode):
/// `backgroundPrimary` < `backgroundSecondary` < `surfacePrimary` < `surfaceSecondary` < `surfaceTertiary`
///
/// Accent palette: `accentPrimary` (brand CTA), `accentSecondary` (decorative),
/// `accentRecording` (live recording only — do not repurpose for other red states).
struct ThemeColors {
    let backgroundPrimary: Color
    let backgroundSecondary: Color
    let surfacePrimary: Color
    let surfaceSecondary: Color
    let surfaceTertiary: Color
    let accentPrimary: Color
    let accentSecondary: Color
    let accentRecording: Color
    let accentSuccess: Color
    let accentWarning: Color
    let accentError: Color
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let textOnAccent: Color
    let textPlaceholder: Color
    let divider: Color
    let border: Color
    let borderStrong: Color
    let overlay: Color
    let scrim: Color
}

// MARK: - Typography

struct ThemeTypography {
    let displayLarge: Font
    let displayMedium: Font
    let headlineLarge: Font
    let headlineMedium: Font
    let headlineSmall: Font
    let bodyLarge: Font
    let bodyMedium: Font
    let bodySmall: Font
    let labelLarge: Font
    let labelMedium: Font
    let labelSmall: Font
    let timer: Font
    let timerSmall: Font
    let caption: Font

    static let `default` = ThemeTypography(
        displayLarge: .system(size: 34, weight: .bold),
        displayMedium: .system(size: 28, weight: .bold),
        headlineLarge: .system(size: 22, weight: .bold),
        headlineMedium: .system(size: 18, weight: .semibold),
        headlineSmall: .system(size: 16, weight: .semibold),
        bodyLarge: .system(size: 17, weight: .regular),
        bodyMedium: .system(size: 16, weight: .regular),
        bodySmall: .system(size: 14, weight: .regular),
        labelLarge: .system(size: 14, weight: .medium),
        labelMedium: .system(size: 13, weight: .medium),
        labelSmall: .system(size: 12, weight: .medium),
        timer: .system(size: 64, weight: .thin, design: .monospaced),
        timerSmall: .system(size: 28, weight: .thin, design: .monospaced),
        caption: .system(size: 13, weight: .regular)
    )
}

// MARK: - Spacing

struct ThemeSpacing {
    let xxs: CGFloat
    let xs: CGFloat
    let s: CGFloat
    let m: CGFloat
    let l: CGFloat
    let xl: CGFloat
    let xxl: CGFloat
    let xxxl: CGFloat
    let huge: CGFloat
    let hero: CGFloat

    static let `default` = ThemeSpacing(
        xxs: 2, xs: 4, s: 8, m: 12, l: 16, xl: 20,
        xxl: 24, xxxl: 32, huge: 48, hero: 64
    )
}

// MARK: - Radius

struct ThemeRadius {
    let s: CGFloat
    let m: CGFloat
    let l: CGFloat
    let xl: CGFloat
    let xxl: CGFloat
    let pill: CGFloat
    let card: CGFloat
    let sheet: CGFloat

    static let `default` = ThemeRadius(
        s: 6, m: 10, l: 14, xl: 20, xxl: 28,
        pill: 100, card: 16, sheet: 24
    )
}

// MARK: - Shadows

struct ThemeShadow {
    struct Style {
        let color: Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat
    }

    let card: Style
    let elevated: Style
    let recording: Style
    let modal: Style
}

// MARK: - Gradients

struct ThemeGradients {
    let recordingGlow: RadialGradient
    let heroBackground: LinearGradient
    let activeRecording: LinearGradient
    let cardAccent: LinearGradient
}

// MARK: - AppTheme

struct AppTheme {
    let name: String
    let colorScheme: ColorScheme
    let colors: ThemeColors
    let typography: ThemeTypography
    let spacing: ThemeSpacing
    let radius: ThemeRadius
    let shadows: ThemeShadow
    let gradients: ThemeGradients
}

// MARK: - Presets

extension AppTheme {
    static let midnightIndigo: AppTheme = {
        let recordingRed = Color(red: 1.0, green: 0.302, blue: 0.427)
        let indigo = Color(red: 0.424, green: 0.388, blue: 1.0)

        let colors = ThemeColors(
            backgroundPrimary: Color(red: 0.051, green: 0.051, blue: 0.071),
            backgroundSecondary: Color(red: 0.071, green: 0.071, blue: 0.098),
            surfacePrimary: Color(red: 0.102, green: 0.102, blue: 0.141),
            surfaceSecondary: Color(red: 0.133, green: 0.133, blue: 0.180),
            surfaceTertiary: Color(red: 0.165, green: 0.165, blue: 0.216),
            accentPrimary: indigo,
            accentSecondary: Color(red: 0.0, green: 0.831, blue: 1.0),
            accentRecording: recordingRed,
            accentSuccess: Color(red: 0.0, green: 0.784, blue: 0.588),
            accentWarning: Color(red: 1.0, green: 0.722, blue: 0.0),
            accentError: Color(red: 1.0, green: 0.255, blue: 0.255),
            textPrimary: Color(red: 0.941, green: 0.937, blue: 0.910),
            textSecondary: Color(red: 0.545, green: 0.561, blue: 0.659),
            textTertiary: Color(red: 0.376, green: 0.388, blue: 0.471),
            textOnAccent: .white,
            textPlaceholder: Color(red: 0.376, green: 0.388, blue: 0.471).opacity(0.7),
            divider: Color.white.opacity(0.08),
            border: Color.white.opacity(0.10),
            borderStrong: Color.white.opacity(0.20),
            overlay: Color.black.opacity(0.5),
            scrim: Color.black.opacity(0.75)
        )

        let shadows = ThemeShadow(
            card: .init(color: .black.opacity(0.30), radius: 12, x: 0, y: 4),
            elevated: .init(color: .black.opacity(0.40), radius: 20, x: 0, y: 8),
            recording: .init(color: recordingRed.opacity(0.50), radius: 32, x: 0, y: 0),
            modal: .init(color: .black.opacity(0.60), radius: 40, x: 0, y: -4)
        )

        let gradients = ThemeGradients(
            recordingGlow: RadialGradient(
                colors: [recordingRed.opacity(0.30), .clear],
                center: .center, startRadius: 55, endRadius: 140
            ),
            heroBackground: LinearGradient(
                colors: [
                    Color(red: 0.051, green: 0.051, blue: 0.071),
                    Color(red: 0.071, green: 0.063, blue: 0.118)
                ],
                startPoint: .top, endPoint: .bottom
            ),
            activeRecording: LinearGradient(
                colors: [
                    Color(red: 0.075, green: 0.051, blue: 0.075),
                    Color(red: 0.051, green: 0.051, blue: 0.071)
                ],
                startPoint: .top, endPoint: .bottom
            ),
            cardAccent: LinearGradient(
                colors: [indigo.opacity(0.08), .clear],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )

        return AppTheme(
            name: "Midnight Indigo",
            colorScheme: .dark,
            colors: colors,
            typography: .default,
            spacing: .default,
            radius: .default,
            shadows: shadows,
            gradients: gradients
        )
    }()

    static let graphiteCrimson: AppTheme = {
        let crimson = Color(red: 0.898, green: 0.243, blue: 0.243)
        let recordingRed = Color(red: 1.0, green: 0.176, blue: 0.176)

        let colors = ThemeColors(
            backgroundPrimary: Color(red: 0.059, green: 0.059, blue: 0.059),
            backgroundSecondary: Color(red: 0.078, green: 0.078, blue: 0.078),
            surfacePrimary: Color(red: 0.110, green: 0.110, blue: 0.110),
            surfaceSecondary: Color(red: 0.145, green: 0.145, blue: 0.145),
            surfaceTertiary: Color(red: 0.180, green: 0.180, blue: 0.180),
            accentPrimary: crimson,
            accentSecondary: Color(red: 1.0, green: 0.549, blue: 0.0),
            accentRecording: recordingRed,
            accentSuccess: Color(red: 0.220, green: 0.631, blue: 0.412),
            accentWarning: Color(red: 0.839, green: 0.620, blue: 0.180),
            accentError: Color(red: 1.0, green: 0.200, blue: 0.200),
            textPrimary: Color(red: 0.969, green: 0.969, blue: 0.961),
            textSecondary: Color(red: 0.620, green: 0.620, blue: 0.620),
            textTertiary: Color(red: 0.459, green: 0.459, blue: 0.459),
            textOnAccent: .white,
            textPlaceholder: Color(red: 0.459, green: 0.459, blue: 0.459).opacity(0.7),
            divider: Color.white.opacity(0.07),
            border: Color.white.opacity(0.09),
            borderStrong: Color.white.opacity(0.18),
            overlay: Color.black.opacity(0.5),
            scrim: Color.black.opacity(0.75)
        )

        let shadows = ThemeShadow(
            card: .init(color: .black.opacity(0.35), radius: 10, x: 0, y: 3),
            elevated: .init(color: .black.opacity(0.45), radius: 18, x: 0, y: 7),
            recording: .init(color: recordingRed.opacity(0.50), radius: 32, x: 0, y: 0),
            modal: .init(color: .black.opacity(0.60), radius: 40, x: 0, y: -4)
        )

        let gradients = ThemeGradients(
            recordingGlow: RadialGradient(
                colors: [crimson.opacity(0.30), .clear],
                center: .center, startRadius: 55, endRadius: 140
            ),
            heroBackground: LinearGradient(
                colors: [
                    Color(red: 0.059, green: 0.059, blue: 0.059),
                    Color(red: 0.078, green: 0.063, blue: 0.063)
                ],
                startPoint: .top, endPoint: .bottom
            ),
            activeRecording: LinearGradient(
                colors: [
                    Color(red: 0.098, green: 0.059, blue: 0.059),
                    Color(red: 0.059, green: 0.059, blue: 0.059)
                ],
                startPoint: .top, endPoint: .bottom
            ),
            cardAccent: LinearGradient(
                colors: [crimson.opacity(0.07), .clear],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )

        return AppTheme(
            name: "Graphite Crimson",
            colorScheme: .dark,
            colors: colors,
            typography: .default,
            spacing: .default,
            radius: .default,
            shadows: shadows,
            gradients: gradients
        )
    }()

    static let electricLime: AppTheme = {
        let lime = Color(red: 0.40, green: 0.65, blue: 0.0)            // #66A600 — electric lime (darkened for white text contrast)
        let recordingAmber = Color(red: 1.0, green: 0.502, blue: 0.0) // #FF8000 — amber for live recording

        let colors = ThemeColors(
            backgroundPrimary:  Color(red: 0.039, green: 0.055, blue: 0.027),
            backgroundSecondary: Color(red: 0.055, green: 0.075, blue: 0.039),
            surfacePrimary:     Color(red: 0.082, green: 0.110, blue: 0.055),
            surfaceSecondary:   Color(red: 0.110, green: 0.145, blue: 0.075),
            surfaceTertiary:    Color(red: 0.137, green: 0.180, blue: 0.094),
            accentPrimary:      lime,
            accentSecondary:    Color(red: 0.0, green: 0.902, blue: 0.502),    // neon mint
            accentRecording:    recordingAmber,
            accentSuccess:      Color(red: 0.549, green: 0.902, blue: 0.0),
            accentWarning:      Color(red: 1.0, green: 0.780, blue: 0.0),
            accentError:        Color(red: 1.0, green: 0.255, blue: 0.255),
            textPrimary:        Color(red: 0.922, green: 0.961, blue: 0.859),
            textSecondary:      Color(red: 0.490, green: 0.569, blue: 0.376),
            textTertiary:       Color(red: 0.318, green: 0.376, blue: 0.243),
            textOnAccent:       .white,
            textPlaceholder:    Color(red: 0.318, green: 0.376, blue: 0.243).opacity(0.7),
            divider:            Color.white.opacity(0.08),
            border:             Color.white.opacity(0.10),
            borderStrong:       Color.white.opacity(0.20),
            overlay:            Color.black.opacity(0.5),
            scrim:              Color.black.opacity(0.75)
        )

        let shadows = ThemeShadow(
            card:      .init(color: .black.opacity(0.35), radius: 12, x: 0, y: 4),
            elevated:  .init(color: .black.opacity(0.45), radius: 20, x: 0, y: 8),
            recording: .init(color: recordingAmber.opacity(0.50), radius: 32, x: 0, y: 0),
            modal:     .init(color: .black.opacity(0.60), radius: 40, x: 0, y: -4)
        )

        let gradients = ThemeGradients(
            recordingGlow: RadialGradient(
                colors: [recordingAmber.opacity(0.30), .clear],
                center: .center, startRadius: 55, endRadius: 140
            ),
            heroBackground: LinearGradient(
                colors: [
                    Color(red: 0.039, green: 0.055, blue: 0.027),
                    Color(red: 0.055, green: 0.082, blue: 0.035)
                ],
                startPoint: .top, endPoint: .bottom
            ),
            activeRecording: LinearGradient(
                colors: [
                    Color(red: 0.071, green: 0.055, blue: 0.027),
                    Color(red: 0.039, green: 0.055, blue: 0.027)
                ],
                startPoint: .top, endPoint: .bottom
            ),
            cardAccent: LinearGradient(
                colors: [lime.opacity(0.07), .clear],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )

        return AppTheme(
            name: "Electric Lime",
            colorScheme: .dark,
            colors: colors,
            typography: .default,
            spacing: .default,
            radius: .default,
            shadows: shadows,
            gradients: gradients
        )
    }()

    static let daylightIndigo: AppTheme = {
        let indigo = Color(red: 0.337, green: 0.290, blue: 0.898)        // vivid indigo
        let recordingRed = Color(red: 0.937, green: 0.231, blue: 0.380)  // coral red

        let colors = ThemeColors(
            backgroundPrimary:   Color(red: 0.949, green: 0.949, blue: 0.969),
            backgroundSecondary: Color(red: 0.929, green: 0.929, blue: 0.953),
            surfacePrimary:      .white,
            surfaceSecondary:    Color(red: 0.957, green: 0.957, blue: 0.980),
            surfaceTertiary:     Color(red: 0.929, green: 0.929, blue: 0.961),
            accentPrimary:       indigo,
            accentSecondary:     Color(red: 0.439, green: 0.678, blue: 0.980), // sky blue
            accentRecording:     recordingRed,
            accentSuccess:       Color(red: 0.196, green: 0.659, blue: 0.416),
            accentWarning:       Color(red: 0.918, green: 0.612, blue: 0.0),
            accentError:         Color(red: 0.863, green: 0.200, blue: 0.200),
            textPrimary:         Color(red: 0.086, green: 0.082, blue: 0.149),
            textSecondary:       Color(red: 0.376, green: 0.369, blue: 0.518),
            textTertiary:        Color(red: 0.573, green: 0.569, blue: 0.682),
            textOnAccent:        .white,
            textPlaceholder:     Color(red: 0.573, green: 0.569, blue: 0.682).opacity(0.7),
            divider:             Color.black.opacity(0.08),
            border:              Color.black.opacity(0.10),
            borderStrong:        Color.black.opacity(0.22),
            overlay:             Color.black.opacity(0.35),
            scrim:               Color.black.opacity(0.55)
        )

        let shadows = ThemeShadow(
            card:      .init(color: indigo.opacity(0.10), radius: 12, x: 0, y: 4),
            elevated:  .init(color: indigo.opacity(0.16), radius: 20, x: 0, y: 8),
            recording: .init(color: recordingRed.opacity(0.35), radius: 32, x: 0, y: 0),
            modal:     .init(color: .black.opacity(0.20), radius: 40, x: 0, y: -4)
        )

        let gradients = ThemeGradients(
            recordingGlow: RadialGradient(
                colors: [recordingRed.opacity(0.18), .clear],
                center: .center, startRadius: 55, endRadius: 140
            ),
            heroBackground: LinearGradient(
                colors: [
                    Color(red: 0.949, green: 0.949, blue: 0.969),
                    Color(red: 0.929, green: 0.941, blue: 0.984)
                ],
                startPoint: .top, endPoint: .bottom
            ),
            activeRecording: LinearGradient(
                colors: [
                    Color(red: 0.980, green: 0.945, blue: 0.953),
                    Color(red: 0.949, green: 0.949, blue: 0.969)
                ],
                startPoint: .top, endPoint: .bottom
            ),
            cardAccent: LinearGradient(
                colors: [indigo.opacity(0.06), .clear],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )

        return AppTheme(
            name: "Daylight Indigo",
            colorScheme: .light,
            colors: colors,
            typography: .default,
            spacing: .default,
            radius: .default,
            shadows: shadows,
            gradients: gradients
        )
    }()
}

// MARK: - Theme Manager

/// To add a new theme:
/// 1. Add a case here and wire `displayName`, `theme`, and `previewColors`.
/// 2. Add a `static let yourTheme: AppTheme` extension on `AppTheme` below.
enum ThemePreset: String, CaseIterable, Identifiable {
    case midnightIndigo
    case graphiteCrimson
    case electricLime
    case daylightIndigo

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .midnightIndigo:  return "Midnight Indigo"
        case .graphiteCrimson: return "Graphite Crimson"
        case .electricLime:    return "Electric Lime"
        case .daylightIndigo:  return "Daylight Indigo"
        }
    }

    var theme: AppTheme {
        switch self {
        case .midnightIndigo:  return .midnightIndigo
        case .graphiteCrimson: return .graphiteCrimson
        case .electricLime:    return .electricLime
        case .daylightIndigo:  return .daylightIndigo
        }
    }

    var previewColors: (Color, Color) {
        switch self {
        case .midnightIndigo:
            return (Color(red: 0.051, green: 0.051, blue: 0.071), Color(red: 0.424, green: 0.388, blue: 1.0))
        case .graphiteCrimson:
            return (Color(red: 0.059, green: 0.059, blue: 0.059), Color(red: 0.898, green: 0.243, blue: 0.243))
        case .electricLime:
            return (Color(red: 0.039, green: 0.055, blue: 0.027), Color(red: 0.749, green: 1.0, blue: 0.0))
        case .daylightIndigo:
            return (Color(red: 0.949, green: 0.949, blue: 0.969), Color(red: 0.337, green: 0.290, blue: 0.898))
        }
    }
}

/// The active theme for the app. Created once in `ContentView` as `@State` and
/// injected everywhere via `.environment(themeManager)`.
///
/// In any view: `@Environment(ThemeManager.self) private var themeManager`
/// Then: `let t = themeManager.currentTheme` and use `t.colors.*`, `t.typography.*`, etc.
///
/// `currentPreset` is persisted to `UserDefaults`. Setting it updates `currentTheme`
/// and all observing views re-render automatically via `@Observable`.
@Observable final class ThemeManager {
    var currentTheme: AppTheme = .midnightIndigo
    var currentPreset: ThemePreset = .midnightIndigo {
        didSet {
            currentTheme = currentPreset.theme
            UserDefaults.standard.set(currentPreset.rawValue, forKey: "selectedTheme")
        }
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: "selectedTheme") ?? ""
        let preset = ThemePreset(rawValue: saved) ?? .midnightIndigo
        currentPreset = preset
        currentTheme = preset.theme
    }
}
