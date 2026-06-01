import SwiftUI

// Lightweight theme for watchOS — mirrors the iOS AppTheme tokens
struct WatchTheme {
    let backgroundPrimary: Color
    let surfacePrimary: Color
    let accentPrimary: Color
    let accentRecording: Color
    let accentSuccess: Color
    let textPrimary: Color
    let textSecondary: Color

    static let midnightIndigo = WatchTheme(
        backgroundPrimary: Color(red: 0.051, green: 0.051, blue: 0.071),
        surfacePrimary: Color(red: 0.102, green: 0.102, blue: 0.141),
        accentPrimary: Color(red: 0.424, green: 0.388, blue: 1.0),
        accentRecording: Color(red: 1.0, green: 0.302, blue: 0.427),
        accentSuccess: Color(red: 0.0, green: 0.784, blue: 0.588),
        textPrimary: Color(red: 0.941, green: 0.937, blue: 0.910),
        textSecondary: Color(red: 0.545, green: 0.561, blue: 0.659)
    )
}

// MARK: - Watch Recording Orb

struct WatchRecordingOrb: View {
    let color: Color
    let isRecording: Bool

    @State private var pulsing = false

    var body: some View {
        ZStack {
            if isRecording {
                Circle()
                    .fill(color.opacity(0.2))
                    .scaleEffect(pulsing ? 1.25 : 0.95)
                    .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulsing)
            }
            Circle()
                .fill(color)
                .shadow(color: color.opacity(isRecording ? 0.6 : 0.2), radius: isRecording ? 10 : 4)
        }
        .onAppear { pulsing = true }
    }
}

// MARK: - Watch Utilities

extension TimeInterval {
    var timerString: String {
        let h = Int(self) / 3600
        let m = (Int(self) % 3600) / 60
        let s = Int(self) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Watch Waveform

struct WatchWaveformView: View {
    let levels: [Float]
    let color: Color
    var highlightedBars: Set<Int> = []
    var highlightColor: Color = .red
    private let barSpacing: CGFloat = 1.5

    var body: some View {
        GeometryReader { geo in
            let count = levels.count
            let totalSpacing = barSpacing * CGFloat(count - 1)
            let barWidth = max(1.5, (geo.size.width - totalSpacing) / CGFloat(count))

            HStack(spacing: barSpacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                    let isHighlighted = highlightedBars.contains(index)
                    let h = max(2, CGFloat(level) * geo.size.height)
                    RoundedRectangle(cornerRadius: barWidth / 2)
                        .fill(isHighlighted ? highlightColor : color)
                        .frame(width: barWidth, height: h)
                        .animation(.easeOut(duration: 0.18), value: level)
                        .animation(.easeInOut(duration: 0.12), value: isHighlighted)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}
