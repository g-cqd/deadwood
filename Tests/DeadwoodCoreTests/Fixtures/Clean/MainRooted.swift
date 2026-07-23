// swift-format-ignore-file
// @main-rooted graph: every private helper hangs off the entry point, so
// the whole file is reachable.
@main
struct Tool {
    static func main() {
        let store = Store()
        store.record(Event(name: "launch"))
        report(store)
    }
}

private struct Event {
    let name: String
}

private final class Store {
    private(set) var events: [Event] = []

    func record(_ event: Event) {
        events.append(event)
    }
}

private func report(_ store: Store) {
    for event in store.events {
        print(event.name)
    }
}
