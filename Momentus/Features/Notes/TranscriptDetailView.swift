import SwiftUI

struct TranscriptDetailView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss
    let transcript: Transcript
    let recordingTitle: String

    @State private var searchText = ""
    @State private var selectedSpeakerId: UUID?
    @State private var editingSegmentId: UUID?

    private var speakers: [Speaker] { transcript.speakers }

    private var displaySegments: [TranscriptSegment] {
        transcript.segments.compactMap { segment in
            guard let cleanedText = TranscriptTextSanitizer.cleaned(segment.text) else { return nil }
            var cleanedSegment = segment
            cleanedSegment.text = cleanedText
            return cleanedSegment
        }
    }

    private var filteredSegments: [TranscriptSegment] {
        var segs = displaySegments
        if let spk = selectedSpeakerId {
            segs = segs.filter { $0.speakerId == spk }
        }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            segs = segs.filter { $0.text.lowercased().contains(q) }
        }
        return segs
    }

    var body: some View {
        let t = themeManager.currentTheme
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    speakerFilter(t)
                        .padding(.vertical, t.spacing.m)

                    if filteredSegments.isEmpty {
                        emptyState(t)
                    } else {
                        ForEach(filteredSegments) { segment in
                            TranscriptSegmentRow(
                                segment: segment,
                                speaker: speakers.first { $0.id == segment.speakerId },
                                isHighlighted: !searchText.isEmpty && segment.text.localizedCaseInsensitiveContains(searchText)
                            )
                            .environment(themeManager)
                            .padding(.horizontal, t.spacing.l)
                            .padding(.vertical, t.spacing.s)
                        }
                    }
                }
                .padding(.bottom, t.spacing.huge)
            }
            .background(t.colors.backgroundPrimary)
            .navigationTitle("Transcript")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search transcript")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(t.colors.textSecondary)
                }
            }
        }
    }

    // MARK: - Speaker Filter

    private func speakerFilter(_ t: AppTheme) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: t.spacing.s) {
                FilterChip(label: "All", isSelected: selectedSpeakerId == nil) {
                    selectedSpeakerId = nil
                }
                .environment(themeManager)

                ForEach(speakers) { speaker in
                    FilterChip(
                        label: speaker.name,
                        isSelected: selectedSpeakerId == speaker.id
                    ) {
                        selectedSpeakerId = selectedSpeakerId == speaker.id ? nil : speaker.id
                    }
                    .environment(themeManager)
                }
            }
            .padding(.horizontal, t.spacing.l)
        }
    }

    private func emptyState(_ t: AppTheme) -> some View {
        VStack(spacing: t.spacing.m) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(t.colors.textTertiary)
            Text("No segments match")
                .font(t.typography.bodyMedium)
                .foregroundStyle(t.colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(t.spacing.huge)
    }
}

// MARK: - Transcript Segment Row

struct TranscriptSegmentRow: View {
    @Environment(ThemeManager.self) private var themeManager
    let segment: TranscriptSegment
    let speaker: Speaker?
    var isHighlighted: Bool = false
    private var needsReview: Bool { segment.confidence < 0.55 }

    var body: some View {
        let t = themeManager.currentTheme
        HStack(alignment: .top, spacing: t.spacing.m) {
            VStack(alignment: .trailing, spacing: 3) {
                Text(formatTimestamp(segment.startTime))
                    .font(t.typography.labelSmall)
                    .foregroundStyle(t.colors.textTertiary)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)

                if let spk = speaker {
                    Circle()
                        .fill(Color(hex: spk.colorHex))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                if let spk = speaker {
                    HStack(spacing: 4) {
                        Text(spk.name)
                            .font(t.typography.labelLarge)
                            .foregroundStyle(Color(hex: spk.colorHex))
                        if spk.isNameInferred {
                            Text("· inferred")
                                .font(t.typography.labelSmall)
                                .foregroundStyle(t.colors.textTertiary)
                        }
                    }
                }

                Text(segment.text)
                    .font(t.typography.bodyMedium)
                    .foregroundStyle(segment.isLowConfidence ? t.colors.textSecondary : t.colors.textPrimary)
                    .lineSpacing(3)
                    .background(isHighlighted ? t.colors.accentPrimary.opacity(0.15) : .clear)

                if needsReview {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform.badge.magnifyingglass")
                            .font(.system(size: 11))
                        Text("Audio unclear")
                            .font(t.typography.labelSmall)
                    }
                    .foregroundStyle(t.colors.textTertiary)
                    .accessibilityLabel("Audio unclear in this part of the transcript")
                }
            }
            Spacer()
        }
    }

    private func formatTimestamp(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Color from hex

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

#Preview {
    TranscriptDetailView(
        transcript: MockMeetings.mobileKickoffTranscript,
        recordingTitle: "Mobile App Kickoff"
    )
    .environment(ThemeManager())
    .preferredColorScheme(.dark)
}
