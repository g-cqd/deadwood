// swift-format-ignore-file
// Key-path literals are real references: a property used only through
// `\Type.property` (sorting, KVO, dynamic member lookup) is not unused.
final class Track {
    var title = ""
    var duration = 0.0
}

@main struct KeyPathMain {
    static func main() {
        let tracks = [Track()]
        _ = tracks.sorted { $0[keyPath: \Track.title] < $1[keyPath: \Track.title] }
        _ = tracks.map(\.duration)
    }
}
