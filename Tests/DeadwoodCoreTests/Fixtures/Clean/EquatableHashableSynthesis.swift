//  `==` and `hash(into:)` are invoked by conformance machinery (Set
//  membership, generic Equatable contexts) — never by name. Both must be
//  rooted for conforming types.

private struct Point: Hashable {
    let x: Int
    let y: Int

    static func == (lhs: Point, rhs: Point) -> Bool {
        lhs.x == rhs.x && lhs.y == rhs.y
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(x)
        hasher.combine(y)
    }
}

func containsOrigin(_ points: Set<Point>) -> Bool {
    points.contains(Point(x: 0, y: 0))
}

@main
struct SynthesisMain {
    static func main() {
        _ = containsOrigin([])
    }
}
