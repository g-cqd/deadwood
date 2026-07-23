//  Ported from SwiftStaticAnalysis UnusedCodeDetectorTests/ParallelBFSTests
//  (the stats-collecting variant was trimmed; its scenarios run through the
//  plain entry point here; node ids are dense indices).

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
        let graph = DenseGraph(nodeCount: 0, edges: [], roots: [])
        let reachable = await ParallelBFS.computeReachable(graph: graph)
        #expect(reachable.isEmpty)
    }

    @Test("No roots returns empty result")
    func noRoots() async {
        let graph = DenseGraph(nodeCount: 2, edges: [(0, 1)], roots: [])
        let reachable = await ParallelBFS.computeReachable(graph: graph, configuration: forceParallel)
        #expect(reachable.isEmpty)
    }

    @Test("Single node graph works correctly")
    func singleNode() async {
        let graph = DenseGraph(nodeCount: 1, edges: [], roots: [0])
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
            nodeCount: 5,
            edges: [(0, 1), (2, 3)],
            roots: [0, 2]
        )

        let reachable = await ParallelBFS.computeReachable(graph: graph, configuration: forceParallel)
        #expect(reachable.count == 4)
        #expect(!reachable.contains(4))
    }

    @Test("Very small graph uses sequential fallback")
    func sequentialFallback() async {
        let graph = DenseGraph(nodeCount: 2, edges: [(0, 1)], roots: [0])

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
            nodeCount: 2,
            edges: [(0, 0), (0, 1)],
            roots: [0]
        )

        let reachable = await ParallelBFS.computeReachable(graph: graph, configuration: forceParallel)
        #expect(reachable.count == 2)
    }

    @Test("Diamond dependency pattern")
    func diamondPattern() async {
        //     0
        //    / \
        //   1   2
        //    \ /
        //     3
        let graph = DenseGraph(
            nodeCount: 4,
            edges: [(0, 1), (0, 2), (1, 3), (2, 3)],
            roots: [0]
        )

        let reachable = await ParallelBFS.computeReachable(graph: graph, configuration: forceParallel)
        #expect(reachable.count == 4)
    }

    @Test("Isolated node not reachable")
    func isolatedNode() async {
        let graph = DenseGraph(
            nodeCount: 3,
            edges: [(0, 1)],
            roots: [0]
        )

        let reachable = await ParallelBFS.computeReachable(graph: graph, configuration: forceParallel)
        #expect(!reachable.contains(2))
    }

    @Test("Large graph parallel BFS matches sequential")
    func largeGraphCorrectness() async {
        // 2000-node layered graph with cross edges and an unreachable tail.
        var edges: [(from: Int32, to: Int32)] = []
        for index in 0..<1500 {
            edges.append((from: Int32(index), to: Int32(index + 1)))
            if index % 7 == 0, index + 13 < 1500 {
                edges.append((from: Int32(index), to: Int32(index + 13)))
            }
        }
        // 1502...1999 form a disconnected chain.
        for index in 1502..<1999 {
            edges.append((from: Int32(index), to: Int32(index + 1)))
        }

        let graph = DenseGraph(nodeCount: 2000, edges: edges, roots: [0])

        let sequential = graph.computeReachableSequential()
        let parallel = await ParallelBFS.computeReachable(graph: graph, configuration: forceParallel)

        #expect(sequential == parallel)
        #expect(sequential.count == 1501)  // 0...1500 inclusive.
    }

    @Test("Dense graph (bottom-up trigger) matches sequential")
    func denseGraphBottomUp() async {
        // Dense fan-out: every node points at many others so the frontier
        // edge count trips the bottom-up switch immediately (alpha = 1).
        var edges: [(from: Int32, to: Int32)] = []
        let count = 128
        for from in 0..<count {
            for offset in 1...8 {
                edges.append((from: Int32(from), to: Int32((from + offset) % count)))
            }
        }

        let graph = DenseGraph(nodeCount: count, edges: edges, roots: [0])
        let config = ParallelBFS.Configuration(alpha: 1, beta: 100, minParallelSize: 1)

        let sequential = graph.computeReachableSequential()
        let parallel = await ParallelBFS.computeReachable(graph: graph, configuration: config)

        #expect(sequential == parallel)
        #expect(sequential.count == count)
    }

    // MARK: - Helpers

    private func chainGraph(length: Int) -> DenseGraph {
        var edges: [(from: Int32, to: Int32)] = []
        for index in 1..<length {
            edges.append((from: Int32(index - 1), to: Int32(index)))
        }
        return DenseGraph(nodeCount: length, edges: edges, roots: [0])
    }
}
