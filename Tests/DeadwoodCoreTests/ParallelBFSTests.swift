//  Ported from SwiftStaticAnalysis UnusedCodeDetectorTests/ParallelBFSTests
//  (the stats-collecting variant was trimmed; its scenarios run through the
//  plain entry point here).

import Testing

@testable import DeadwoodCore

@Suite("Parallel BFS")
struct ParallelBFSTests {
    /// Force the parallel path regardless of graph size.
    private var forceParallel: ParallelBFS.Configuration {
        ParallelBFS.Configuration(minParallelSize: 1)
    }

    @Test("Empty graph returns empty result")
    func emptyGraph() async {
        let graph = DenseGraph(nodeIds: [], edges: [], rootIds: [])
        let reachable = await ParallelBFS.computeReachable(graph: graph)
        #expect(reachable.isEmpty)
    }

    @Test("No roots returns empty result")
    func noRoots() async {
        let graph = DenseGraph(nodeIds: ["A", "B"], edges: [("A", "B")], rootIds: [])
        let reachable = await ParallelBFS.computeReachable(graph: graph, configuration: forceParallel)
        #expect(reachable.isEmpty)
    }

    @Test("Single node graph works correctly")
    func singleNode() async {
        let graph = DenseGraph(nodeIds: ["A"], edges: [], rootIds: ["A"])
        let reachable = await ParallelBFS.computeReachable(graph: graph, configuration: forceParallel)
        #expect(reachable == [0])
    }

    @Test("Parallel BFS is deterministic across multiple runs")
    func deterministicRuns() async {
        let graph = chainGraph(length: 64)

        var results: Set<Set<Int>> = []
        for _ in 0..<5 {
            let reachable = await ParallelBFS.computeReachable(
                graph: graph, configuration: forceParallel)
            results.insert(reachable)
        }
        #expect(results.count == 1)
    }

    @Test("Multiple roots work correctly")
    func multipleRoots() async {
        let graph = DenseGraph(
            nodeIds: ["A", "B", "C", "D", "E"],
            edges: [("A", "B"), ("C", "D")],
            rootIds: ["A", "C"]
        )

        let reachable = await ParallelBFS.computeReachable(graph: graph, configuration: forceParallel)
        #expect(reachable.count == 4)
        #expect(!reachable.contains(graph.nodeToIndex["E"]!))
    }

    @Test("Very small graph uses sequential fallback")
    func sequentialFallback() async {
        let graph = DenseGraph(nodeIds: ["A", "B"], edges: [("A", "B")], rootIds: ["A"])

        // Default configuration: 2 nodes < minParallelSize (1000).
        let reachable = await ParallelBFS.computeReachable(graph: graph)
        #expect(reachable.count == 2)
    }

    @Test("Invalid config values are clamped to valid range")
    func configClamping() {
        let config = ParallelBFS.Configuration(
            alpha: -5,
            beta: 1_000_000,
            minParallelSize: 0,
            maxConcurrency: 0
        )

        #expect(config.alpha == 1)
        #expect(config.beta == 100)
        #expect(config.minParallelSize == 1)
        #expect(config.maxConcurrency == 1)
    }

    @Test("Self-loops are handled correctly")
    func selfLoops() async {
        let graph = DenseGraph(
            nodeIds: ["A", "B"],
            edges: [("A", "A"), ("A", "B")],
            rootIds: ["A"]
        )

        let reachable = await ParallelBFS.computeReachable(graph: graph, configuration: forceParallel)
        #expect(reachable.count == 2)
    }

    @Test("Duplicate roots are handled correctly")
    func duplicateRoots() async {
        let graph = DenseGraph(
            nodeIds: ["A", "B"],
            edges: [("A", "B")],
            rootIds: ["A"]  // Set semantics already dedupe.
        )

        let reachable = await ParallelBFS.computeReachable(graph: graph, configuration: forceParallel)
        #expect(reachable.count == 2)
    }

    @Test("Diamond dependency pattern")
    func diamondPattern() async {
        //     A
        //    / \
        //   B   C
        //    \ /
        //     D
        let graph = DenseGraph(
            nodeIds: ["A", "B", "C", "D"],
            edges: [("A", "B"), ("A", "C"), ("B", "D"), ("C", "D")],
            rootIds: ["A"]
        )

        let reachable = await ParallelBFS.computeReachable(graph: graph, configuration: forceParallel)
        #expect(reachable.count == 4)
    }

    @Test("Isolated node not reachable")
    func isolatedNode() async {
        let graph = DenseGraph(
            nodeIds: ["A", "B", "Isolated"],
            edges: [("A", "B")],
            rootIds: ["A"]
        )

        let reachable = await ParallelBFS.computeReachable(graph: graph, configuration: forceParallel)
        #expect(!reachable.contains(graph.nodeToIndex["Isolated"]!))
    }

    @Test("Large graph parallel BFS matches sequential")
    func largeGraphCorrectness() async {
        // 2000-node layered graph with cross edges and an unreachable tail.
        var nodeIds: [String] = []
        var edges: [(from: String, to: String)] = []
        for index in 0..<2000 {
            nodeIds.append("n\(index)")
        }
        for index in 0..<1500 {
            edges.append((from: "n\(index)", to: "n\(index + 1)"))
            if index % 7 == 0, index + 13 < 1500 {
                edges.append((from: "n\(index)", to: "n\(index + 13)"))
            }
        }
        // n1502...n1999 form a disconnected chain.
        for index in 1502..<1999 {
            edges.append((from: "n\(index)", to: "n\(index + 1)"))
        }

        let graph = DenseGraph(nodeIds: nodeIds, edges: edges, rootIds: ["n0"])

        let sequential = graph.computeReachableSequential()
        let parallel = await ParallelBFS.computeReachable(graph: graph, configuration: forceParallel)

        #expect(sequential == parallel)
        #expect(sequential.count == 1501)  // n0...n1500 inclusive.
    }

    @Test("Dense graph (bottom-up trigger) matches sequential")
    func denseGraphBottomUp() async {
        // Dense fan-out: every node points at many others so the frontier
        // edge count trips the bottom-up switch immediately (alpha = 1).
        var nodeIds: [String] = []
        var edges: [(from: String, to: String)] = []
        let count = 128
        for index in 0..<count {
            nodeIds.append("n\(index)")
        }
        for from in 0..<count {
            for offset in 1...8 {
                edges.append((from: "n\(from)", to: "n\((from + offset) % count)"))
            }
        }

        let graph = DenseGraph(nodeIds: nodeIds, edges: edges, rootIds: ["n0"])
        let config = ParallelBFS.Configuration(alpha: 1, beta: 100, minParallelSize: 1)

        let sequential = graph.computeReachableSequential()
        let parallel = await ParallelBFS.computeReachable(graph: graph, configuration: config)

        #expect(sequential == parallel)
        #expect(sequential.count == count)
    }

    // MARK: - Helpers

    private func chainGraph(length: Int) -> DenseGraph {
        var nodeIds: [String] = []
        var edges: [(from: String, to: String)] = []
        for index in 0..<length {
            nodeIds.append("n\(index)")
            if index > 0 {
                edges.append((from: "n\(index - 1)", to: "n\(index)"))
            }
        }
        return DenseGraph(nodeIds: nodeIds, edges: edges, rootIds: ["n0"])
    }
}
