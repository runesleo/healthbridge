import WidgetKit
import SwiftUI

/// Watch-face button: one tap opens HealthBridge straight on the voice-note screen.
struct Entry: TimelineEntry { let date: Date }

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(Entry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: .now)], policy: .never))
    }
}

struct VoiceNoteView: View {
    @Environment(\.widgetFamily) private var family
    private var zh: Bool { (Locale.preferredLanguages.first ?? "").hasPrefix("zh") }
    var body: some View {
        switch family {
        case .accessoryRectangular:
            HStack(spacing: 6) {
                Image(systemName: "mic.fill").font(.title2)
                VStack(alignment: .leading) {
                    Text(zh ? "口述记录" : "Voice note").font(.headline)
                    Text(zh ? "吃喝心情随口说" : "Say anything").font(.caption2).foregroundStyle(.secondary)
                }
            }
        case .accessoryInline:
            Label(zh ? "口述记录" : "Voice note", systemImage: "mic.fill")
        case .accessoryCorner:
            Image(systemName: "mic.fill").font(.title2)
                .widgetLabel(zh ? "口述" : "Voice")
        default:
            ZStack { AccessoryWidgetBackground(); Image(systemName: "mic.fill").font(.title2) }
        }
    }
}

@main
struct HealthBridgeWatchWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "VoiceNote", provider: Provider()) { _ in
            VoiceNoteView().containerBackground(.clear, for: .widget)
                .widgetURL(URL(string: "healthbridge://voice"))
        }
        .configurationDisplayName("口述记录")
        .description("一点就开始说，全都记下")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}
