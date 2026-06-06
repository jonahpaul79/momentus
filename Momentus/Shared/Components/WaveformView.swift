import AVFoundation
import SwiftUI

// MARK: - Live Waveform (recording in progress)

struct WaveformView: View {
    let levels: [Float]
    var color: Color = .white
    var barSpacing: CGFloat = 3
    var highlightedBars: Set<Int> = []
    var highlightColor: Color = .red

    var body: some View {
        GeometryReader { geo in
            let count = levels.count
            let totalSpacing = barSpacing * CGFloat(count - 1)
            let barWidth = (geo.size.width - totalSpacing) / CGFloat(count)

            HStack(spacing: barSpacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                    let isHighlighted = highlightedBars.contains(index)
                    let height = max(4, CGFloat(level) * geo.size.height)
                    RoundedRectangle(cornerRadius: barWidth / 2)
                        .fill(isHighlighted ? highlightColor : color)
                        .frame(width: barWidth, height: height)
                        .animation(.easeOut(duration: 0.10), value: level)
                        .animation(.easeInOut(duration: 0.12), value: isHighlighted)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}

// MARK: - Playback Waveform (shows progress through a recording)

struct PlaybackWaveformView: View {
    var seed: Int = 42
    var barCount: Int = 44
    var progress: Double  // 0...1
    var playedColor: Color
    var unplayedColor: Color
    var height: CGFloat = 40

    private let staticLevels: [CGFloat]

    init(seed: Int, barCount: Int = 44, levels: [CGFloat]? = nil, progress: Double, playedColor: Color, unplayedColor: Color, height: CGFloat = 40) {
        let resolvedBarCount = levels?.count ?? barCount
        self.seed = seed
        self.barCount = resolvedBarCount
        self.progress = max(0, min(1, progress))
        self.playedColor = playedColor
        self.unplayedColor = unplayedColor
        self.height = height
        if let levels {
            staticLevels = levels.map { $0.clamped(to: 0.08...1.0) }
            return
        }
        staticLevels = Self.genericLevels(seed: seed, barCount: resolvedBarCount)
    }

    private static func genericLevels(seed: Int, barCount: Int) -> [CGFloat] {
        var gen = SeededRandom(seed: seed)
        var energy = 0.34 + gen.next() * 0.18
        return (0..<barCount).map { _ in
            let isPause = gen.next() < 0.16
            let burst = gen.next() > 0.84 ? gen.next() * 0.35 : 0
            energy = (energy * 0.62 + gen.next() * 0.38 + burst).clamped(to: 0.12...0.94)
            if isPause {
                return CGFloat(0.08 + gen.next() * 0.16)
            }
            return CGFloat(energy * 0.74 + gen.next() * 0.22).clamped(to: 0.12...1.0)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 2.5
            let barWidth = (geo.size.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount)
            let playedCount = Int(Double(barCount) * progress)
            HStack(spacing: spacing) {
                ForEach(Array(staticLevels.enumerated()), id: \.offset) { index, level in
                    RoundedRectangle(cornerRadius: barWidth / 2)
                        .fill(index <= playedCount ? playedColor : unplayedColor.opacity(0.28))
                        .frame(width: barWidth, height: level * geo.size.height)
                        .animation(.linear(duration: 0.1), value: playedCount)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(height: height)
    }
}

enum AudioWaveformAnalyzer {
    nonisolated static func levels(for fileURL: URL, barCount: Int = 44) throws -> [CGFloat] {
        let file = try AVAudioFile(forReading: fileURL)
        let totalFrames = Int(file.length)
        guard totalFrames > 0 else { return [] }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(min(8192, totalFrames))
        ) else {
            return []
        }

        var sums = Array(repeating: 0.0, count: barCount)
        var counts = Array(repeating: 0, count: barCount)
        let framesPerBar = max(1, Double(totalFrames) / Double(barCount))
        let channelCount = Int(file.processingFormat.channelCount)
        var processedFrames = 0

        while processedFrames < totalFrames {
            let framesToRead = min(Int(buffer.frameCapacity), totalFrames - processedFrames)
            try file.read(into: buffer, frameCount: AVAudioFrameCount(framesToRead))
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0, let channelData = buffer.floatChannelData else { break }

            for frame in 0..<frameLength {
                let barIndex = min(barCount - 1, Int(Double(processedFrames + frame) / framesPerBar))
                var framePower = 0.0
                for channel in 0..<channelCount {
                    let sample = Double(channelData[channel][frame])
                    framePower += sample * sample
                }
                sums[barIndex] += framePower / Double(max(channelCount, 1))
                counts[barIndex] += 1
            }

            processedFrames += frameLength
        }

        let rmsLevels = sums.enumerated().map { index, sum in
            counts[index] > 0 ? sqrt(sum / Double(counts[index])) : 0
        }
        let reference = percentile(rmsLevels.filter { $0 > 0 }, fraction: 0.90)
        guard reference > 0 else { return Array(repeating: 0.08, count: barCount) }

        return rmsLevels.map { rms in
            let normalized = min(1, rms / reference)
            return CGFloat(pow(normalized, 0.55)).clamped(to: 0.08...1.0)
        }
    }

    nonisolated private static func percentile(_ values: [Double], fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * fraction).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
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
    nonisolated func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

private extension Double {
    nonisolated func clamped(to range: ClosedRange<Double>) -> Double {
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
