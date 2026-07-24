// swift-format-ignore-file
// App Intents / Shortcuts / Widgets entry points are instantiated by the OS
// at install/launch with NO in-source call site — a reference graph must root
// them by conformance or it reports every one as dead (real FP on Luce's
// LuceShortcuts: AppShortcutsProvider).
import AppIntents
import WidgetKit

struct AppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] { [] }
}

struct MyWidgetBundle: WidgetBundle {
    var body: some Widget { MyWidget() }
}

struct MyWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "w", provider: Provider()) { _ in EmptyView() }
    }
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry() }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {}
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {}
}

struct Entry: TimelineEntry { var date = Date() }
