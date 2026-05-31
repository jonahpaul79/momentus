import SwiftUI

// MARK: - Live Waveform (recording in progress)

struct WaveformView: View {
    let levels: [Float]
    var color: Color = .white
    var barSpacing: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            let count = levels.count
            let totalSpacing = barSpacing * CGFloat(count - 1)
            let barWidth = (geo.size.width - totalSpacing) / CGFloat(count)

            HStack(spacing: barSpacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    let height = max(4, CGFloat(level) * geo.size.height)
                    RoundedRectangle(cornerRadius: barWidth / 2)
                        .fill(color)
                        .frame(width: barWidth, height: height)
                        .animation(.easeOut(duration: 0.18), value: level)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}

// MARK: - Static Waveform (for recording cards / transcript)

struct StaticWaveformView: View {
    var barCount: Int = 32
    var color: Color
    var height: CGFloat = 24

    private let staticLevels: [CGFloat]

    init(seed: Int = 42, barCount: Int = 32, color: Color, height: CGFloat = 24) {
        self.barCount = barCount
        self.color = color
        self.height = height
        var gen = SeededRandom(seed: seed)
        staticLevels = (0..<barCount).map { i in
            let base = sin(Double(i) / Double(barCount) * .pi)
            let noise = gen.next()
            return CGFloat(base * 0.6 + noise * 0.4).clamped(to: 0.1...1.0)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 2
            let barWidth = (geo.size.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount)
            HStack(spacing: spacing) {
                ForEach(Array(staticLevels.enumerated()), id: \.offset) { _, level in
                    RoundedRectangle(cornerRadius: barWidth / 2)
                        .fill(color.opacity(Double(level)))
                        .frame(width: barWidth, height: level * geo.size.height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(height: height)
    }
}

// MARK: - Seeded random for deterministic waveform previews

private struct SeededRandom {
    private var state: UInt64

    init(seed: Int) { state = UInt64(bitPattern: Int64(seed)) ^ 0x6c62272e07bb0142 }

    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let result = Double((state >> 33) & 0xFFFFFF) / Double(0xFFFFFF)
        return result
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Recording Orb (pulsing red dot when recording)

struct RecordingOrb: View {
    var size: CGFloat = 120
    var color: Color
    var isRecording: Bool
    var isPaused: Bool

    @State private var pulsing = false
    @State private var outerPulsing = false

    var body: some View {
        ZStack {
            if isRecording && !isPaused {
                Circle()
                    .fill(color.opacity(0.10))
                    .frame(width: size * 1.6, height: size * 1.6)
                    .scaleEffect(outerPulsing ? 1.1 : 0.95)
                    .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: outerPulsing)

                Circle()
                    .fill(color.opacity(0.20))
                    .frame(width: size * 1.2, height: size * 1.2)
                    .scaleEffect(pulsing ? 1.08 : 0.96)
                    .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: pulsing)
            }

            Circle()
                .fill(
                    RadialGradient(
                        colors: [color.opacity(0.95), color.opacity(0.70)],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: size * 0.8
                    )
                )
                .frame(width: size, height: size)
                .shadow(color: color.opacity(isRecording ? 0.60 : 0.20), radius: isRecording ? 28 : 8, x: 0, y: 0)
        }
        .onAppear { pulsing = true; outerPulsing = true }
    }
}

// MARK: - Previews

#Preview("Waveform") {
    let levels: [Float] = (0..<40).map { i in
        Float(sin(Double(i) / 5.0) * 0.4 + 0.5)
    }
    return ZStack {
        Color.black
        WaveformView(levels: levels, color: .red)
            .frame(height: 60)
            .padding()
    }
}

#Preview("Static Waveform") {
    ZStack {
        Color.black
        StaticWaveformView(color: .purple, height: 32)
            .padding()
    }
}
