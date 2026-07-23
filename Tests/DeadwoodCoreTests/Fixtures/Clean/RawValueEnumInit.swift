//  Raw-value enum cases are constructed from outside the source through
//  `init(rawValue:)`, and Codable can arrive via extension — the merged
//  conformance list must root the cases either way.

private enum Level: Int {
    case low = 0
    case high = 1
}

private enum Route {
    case home
    case detail
}

extension Route: Codable {}

func readLevel(_ raw: Int) -> Level? {
    Level(rawValue: raw)
}

func defaultRoute() -> Route {
    Route.home
}

@main
struct RawValueMain {
    static func main() {
        _ = readLevel(1)
        _ = defaultRoute()
    }
}
