import AppIntents
import SwiftUI
import WidgetKit

@main
struct MomentusWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        WatchQuickRecordWidget()
    }
}

struct WatchQuickRecordWidget: Widget {
    let kind = "MomentusWatchQuickRecord"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchQuickRecordProvider()) { _ in
            WatchQuickRecordView()
                .containerBackground(for: .widget) {
                    Color.indigo.opacity(0.24)
                }
        }
        .configurationDisplayName("Quick Record")
        .description("Start recording on your Watch in one tap.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private struct WatchQuickRecordEntry: TimelineEntry {
    let date: Date
}

private struct WatchQuickRecordProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchQuickRecordEntry { WatchQuickRecordEntry(date: Date()) }

    func getSnapshot(in context: Context, completion: @escaping (WatchQuickRecordEntry) -> Void) {
        completion(WatchQuickRecordEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchQuickRecordEntry>) -> Void) {
        completion(Timeline(entries: [WatchQuickRecordEntry(date: Date())], policy: .never))
    }
}

private struct WatchQuickRecordView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Button(intent: StartMomentusWatchRecordingIntent()) {
            switch family {
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "mic.fill")
                        .font(.title3.weight(.semibold))
                        .widgetAccentable()
                }
            case .accessoryInline:
                Label("Record with Momentus", systemImage: "mic.fill")
            default:
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill")
                        .font(.title3.weight(.semibold))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Momentus")
                            .font(.headline)
                        Text("Tap to record")
                            .font(.caption2)
                    }
                }
                .widgetAccentable()
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start recording on Apple Watch")
    }
}
