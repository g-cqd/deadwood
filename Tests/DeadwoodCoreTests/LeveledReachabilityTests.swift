import Testing

@testable import DeadwoodCore

@Suite struct LeveledReachabilityTests {
    @Test func `each node gets the lowest level of a root and path reaching it`() {
        // 0 is a production root: 0 → 1 at production, 0 → 2 from debug code.
        // 3 is a preview root: 3 → 2 and 3 → 4 at production level.
        // 5 is reached from nothing.
        var edges = LeveledEdges(nodeCount: 6)
        edges.add(source: 0, targets: [1, 2], levels: [0, 1])
        edges.add(source: 3, targets: [2, 4], levels: [0, 0])

        let levels = LeveledReachability.levels(
            of: edges, roots: [(0, 0), (3, 2)], levelCount: 3)

        #expect(levels == [0, 0, 1, 2, 2, LeveledReachability.unreached])
    }
}
