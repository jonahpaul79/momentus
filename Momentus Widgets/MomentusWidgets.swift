import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct MomentusWidgetBundle: WidgetBundle {
    var body: some Widget {
        QuickRecordWidget()
        RecordingLiveActivityWidget()
    }
}

struct QuickRecordWidget: Widget {
    let kind = "MomentusQuickRecord"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QuickRecordProvider()) { _ in
            QuickRecordWidgetView()
                .containerBackground(for: .widget) {
                    LinearGradient(
                        colors: [Color(red: 0.08, green: 0.07, blue: 0.18), Color(red: 0.20, green: 0.12, blue: 0.42)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
        }
        .configurationDisplayName("Quick Record")
        .description("Start a Momentus recording in one tap.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
}

private struct QuickRecordEntry: TimelineEntry {
    let date: Date
}

private struct QuickRecordProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickRecordEntry { QuickRecordEntry(date: Date()) }

    func getSnapshot(in context: Context, completion: @escaping (QuickRecordEntry) -> Void) {
        completion(QuickRecordEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickRecordEntry>) -> Void) {
        completion(Timeline(entries: [QuickRecordEntry(date: Date())], policy: .never))
    }
}

private struct QuickRecordWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Button(intent: StartMomentusRecordingIntent()) {
            switch family {
            case .accessoryCircular:
                Image(systemName: "mic.fill")
                    .font(.title2.weight(.semibold))
                    .widgetAccentable()
            case .accessoryRectangular:
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill")
                        .font(.headline)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Momentus")
                            .font(.headline)
                        Text("Tap to record")
                            .font(.caption)
                    }
                }
                .widgetAccentable()
            default:
                VStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(Color.indigo.opacity(0.32))
                            .frame(width: 68, height: 68)
                        Circle()
                            .fill(Color.indigo)
                            .frame(width: 52, height: 52)
                        Image(systemName: "mic.fill")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    Text("Record")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("One tap to Momentus")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.72))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start a Momentus recording")
    }
}

struct RecordingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            RecordingActivityLockScreenView(context: context)
                .activityBackgroundTint(Color(red: 0.08, green: 0.07, blue: 0.18))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    RecordingStatusLabel(isPaused: context.state.isPaused)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RecordingElapsedTime(state: context.state, font: .headline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    RecordingActivityControls(state: context.state)
                }
            } compactLeading: {
                Image(systemName: context.state.isPaused ? "pause.fill" : "waveform")
                    .foregroundStyle(context.state.isPaused ? .orange : .red)
            } compactTrailing: {
                RecordingElapsedTime(state: context.state, font: .caption2)
                    .frame(width: 48)
            } minimal: {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
            }
            .keylineTint(.indigo)
        }
    }
}

private struct RecordingActivityLockScreenView: View {
    let context: ActivityViewContext<RecordingActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                RecordingStatusLabel(isPaused: context.state.isPaused)
                Spacer()
                RecordingElapsedTime(state: context.state, font: .title3.weight(.semibold))
            }
            Text(context.attributes.title)
                .font(.headline)
                .lineLimit(1)
            RecordingActivityControls(state: context.state)
        }
        .padding(16)
        .foregroundStyle(.white)
    }
}

private struct RecordingElapsedTime: View {
    let state: RecordingActivityAttributes.ContentState
    let font: Font

    var body: some View {
        Group {
            if let timerStartedAt = state.timerStartedAt {
                Text(
                    timerInterval: timerStartedAt.addingTimeInterval(-state.elapsedTime)...Date.distantFuture,
                    countsDown: false
                )
            } else {
                Text(formattedDuration(state.elapsedTime))
            }
        }
        .font(font.monospacedDigit())
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct RecordingStatusLabel: View {
    let isPaused: Bool

    var body: some View {
        Label(isPaused ? "Paused" : "Recording", systemImage: isPaused ? "pause.fill" : "waveform")
            .font(.headline)
            .foregroundStyle(isPaused ? .orange : .red)
    }
}

private struct RecordingActivityControls: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            Button(intent: ToggleMomentusRecordingIntent()) {
                Label(state.isPaused ? "Resume" : "Pause", systemImage: state.isPaused ? "play.fill" : "pause.fill")
            }
            Button(intent: MarkMomentusRecordingIntent()) {
                Label("Mark \(state.markerCount)", systemImage: "bookmark.fill")
            }
            Spacer()
            Button(intent: StopMomentusRecordingIntent()) {
                Label("Stop", systemImage: "stop.fill")
                    .foregroundStyle(.red)
            }
        }
        .font(.caption.weight(.semibold))
        .buttonStyle(.bordered)
    }
}
