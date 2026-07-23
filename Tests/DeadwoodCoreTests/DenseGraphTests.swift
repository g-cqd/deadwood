//  Ported from SwiftStaticAnalysis UnusedCodeDetectorTests/DenseGraphTests
//  (trimmed to the lifted surface: statistics and neighbor accessors are
//  gone, and so is the String→Int node-id mapping — ids are dense indices).

import Testing

@testable import DeadwoodCore

@Suite("Dense Graph")
struct DenseGraphTests {
    @Test("Empty graph has correct properties")
    func emptyGraph() {
        let graph = DenseGraph(nodeCount: 0, edges: [], roots: [])

        #expect(graph.nodeCount == 0)
        #expect(graph.edgeCount == 0)
        #expect(graph.roots.isEmpty)
        #expect(graph.isEmpty)
    }

    @Test("Adjacency built from the edge list")
    func adjacencyFromEdges() {
        let graph = DenseGraph(
            nodeCount: 3,
            edges: [(0, 1), (0, 2), (1, 2)],
            roots: []
        )

        #expect(graph.adjacency[0].contains(1))
        #expect(graph.adjacency[0].contains(2))
        #expect(graph.adjacency[0].count == 2)
        #expect(graph.adjacency[1] == [2])
        #expect(graph.adjacency[2].isEmpty)
    }

    @Test("Reverse adjacency matches forward adjacency")
    func reverseAdjacency() {
        let graph = DenseGraph(
            nodeCount: 3,
            edges: [(0, 1), (0, 2), (1, 2)],
            roots: []
        )

        #expect(graph.reverseAdjacency[1].contains(0))
        #expect(graph.reverseAdjacency[2].contains(0))
        #expect(graph.reverseAdjacency[2].contains(1))
        #expect(graph.reverseAdjacency[2].count == 2)
        #expect(graph.reverseAdjacency[0].isEmpty)
    }

    @Test("Root indices correctly identified")
    func rootIndices() {
        let graph = DenseGraph(nodeCount: 3, edges: [], roots: [0, 2])

        #expect(graph.roots.count == 2)
        #expect(graph.roots.contains(0))
        #expect(graph.roots.contains(2))
    }

    @Test("Out-of-range edges and roots are skipped")
    func outOfRangeSkipped() {
        let graph = DenseGraph(
            nodeCount: 2,
            edges: [(0, 1), (0, 7), (5, 1), (-1, 0)],
            roots: [0, 9]
        )

        #expect(graph.edgeCount == 1)
        #expect(graph.roots == [0])
    }

    @Test("TotalOutEdges calculates correctly")
    func totalOutEdges() {
        let graph = DenseGraph(
            nodeCount: 3,
            edges: [(0, 1), (0, 2), (1, 2)],
            roots: []
        )

        #expect(graph.totalOutEdges(from: [0]) == 2)
        #expect(graph.totalOutEdges(from: [1]) == 1)
        #expect(graph.totalOutEdges(from: [0, 1]) == 3)
    }

    @Test("Sequential BFS finds all reachable nodes")
    func sequentialBFS() {
        let graph = DenseGraph(
            nodeCount: 5,
            edges: [(0, 1), (1, 2), (2, 3)],
            roots: [0]
        )

        let reachable = graph.computeReachableSequential()

        #expect(reachable.count == 4)
        #expect(!reachable.contains(4))
    }

    @Test("Sequential BFS with multiple roots")
    func sequentialBFSMultipleRoots() {
        let graph = DenseGraph(
            nodeCount: 4,
            edges: [(0, 1), (2, 3)],
            roots: [0, 2]
        )

        #expect(graph.computeReachableSequential().count == 4)
    }

    @Test("Sequential BFS handles cycles")
    func sequentialBFSCycles() {
        let graph = DenseGraph(
            nodeCount: 3,
            edges: [(0, 1), (1, 2), (2, 0)],
            roots: [0]
        )

        #expect(graph.computeReachableSequential().count == 3)
    }

    @Test("ParallelBFS matches sequential reference on a cyclic graph")
    func parallelMatchesSequentialOnCyclicGraph() async {
        //   0 → 1 → 2 → 1   (back edge)
        //       ↓
        //       3
        let graph = DenseGraph(
            nodeCount: 4,
            edges: [(0, 1), (1, 2), (2, 1), (1, 3)],
            roots: [0]
        )

        let sequential = graph.computeReachableSequential()
        let parallel = await ParallelBFS.computeReachable(
            graph: graph,
            configuration: ParallelBFS.Configuration(minParallelSize: 1)
        )

        #expect(sequential == parallel)
        #expect(sequential.count == 4)
    }

    @Test("ParallelBFS matches sequential reference on a disconnected graph")
    func parallelMatchesSequentialOnDisconnectedGraph() async {
        let graph = DenseGraph(
            nodeCount: 6,
            edges: [(0, 1), (1, 2), (3, 4), (4, 5)],
            roots: [0]
        )

        let sequential = graph.computeReachableSequential()
        let parallel = await ParallelBFS.computeReachable(
            graph: graph,
            configuration: ParallelBFS.Configuration(minParallelSize: 1)
        )

        #expect(sequential == parallel)
        #expect(sequential.count == 3)
    }
}
