import SwiftUI
import WidgetKit

private struct VoiceTaskEntry: TimelineEntry {
    let date: Date
}

private struct VoiceTaskProvider: TimelineProvider {
    func placeholder(in context: Context) -> VoiceTaskEntry {
        VoiceTaskEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (VoiceTaskEntry) -> Void) {
        completion(VoiceTaskEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VoiceTaskEntry>) -> Void) {
        let entry = VoiceTaskEntry(date: Date())
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

private struct VoiceTaskWidgetView: View {
    @Environment(\.widgetFamily) private var family

    private var startVoiceURL: URL {
        URL(string: "\(WidgetURLSchemeConfiguration.activeScheme)://shortcut?action=start-voice")!
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            Link(destination: startVoiceURL) {
                Text("Resume Voice Mode")
            }
        case .accessoryRectangular:
            Link(destination: startVoiceURL) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("MOBaiLE")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Label("Resume Voice Mode", systemImage: "mic.fill")
                        .font(.caption.weight(.semibold))
                }
            }
        default:
            Link(destination: startVoiceURL) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "mic.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.blue)
                    Text("Resume Voice Mode")
                        .font(.headline)
                        .lineLimit(2)
                    Text("Open MOBaiLE and return to the active or last voice thread.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
    }
}

struct VoiceTaskWidget: Widget {
    let kind: String = "VoiceTaskWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: VoiceTaskProvider()) { _ in
            VoiceTaskWidgetView()
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Resume Voice Mode")
        .description("Quickly launch MOBaiLE and return to the active or last voice thread.")
        .supportedFamilies([.systemSmall, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct VoiceTaskWidgetBundle: WidgetBundle {
    var body: some Widget {
        VoiceTaskWidget()
    }
}
