//  Ported from SwiftStaticAnalysis UnusedCodeDetectorTests/DenseGraphTests
//  (trimmed to the lifted surface: statistics and neighbor accessors are gone).

import Testing

@testable import DeadwoodCore

@Suite("Dense Graph")
struct DenseGraphTests {
    @Test("Empty graph has correct properties")
    func emptyGraph() {
        let graph = DenseGraph(nodeIds: [], edges: [], rootIds: [])

        #expect(graph.nodeCount == 0)
        #expect(graph.edgeCount == 0)
        #expect(graph.roots.isEmpty)
        #expect(graph.isEmpty)
    }

    @Test("Node ID mapping is bijective")
    func nodeIdMappingBijective() {
        let nodeIds = ["A", "B", "C", "D"]
        let graph = DenseGraph(nodeIds: nodeIds, edges: [], rootIds: [])

        for (index, nodeId) in nodeIds.enumerated() {
            #expect(graph.nodeToIndex[nodeId] == index)
        }
        for (index, nodeId) in graph.indexToNode.enumerated() {
            #expect(nodeIds[index] == nodeId)
        }
    }

    @Test("Adjacency correctly converted from string IDs")
    func adjacencyConversion() {
        let graph = DenseGraph(
            nodeIds: ["A", "B", "C"],
            edges: [("A", "B"), ("A", "C"), ("B", "C")],
            rootIds: []
        )

        let aIndex = graph.nodeToIndex["A"]!
        let bIndex = graph.nodeToIndex["B"]!
        let cIndex = graph.nodeToIndex["C"]!

        #expect(graph.adjacency[aIndex].contains(bIndex))
        #expect(graph.adjacency[aIndex].contains(cIndex))
        #expect(graph.adjacency[aIndex].count == 2)
        #expect(graph.adjacency[bIndex] == [cIndex])
        #expect(graph.adjacency[cIndex].isEmpty)
    }

    @Test("Reverse adjacency matches forward adjacency")
    func reverseAdjacency() {
        let graph = DenseGraph(
            nodeIds: ["A", "B", "C"],
            edges: [("A", "B"), ("A", "C"), ("B", "C")],
            rootIds: []
        )

        let aIndex = graph.nodeToIndex["A"]!
        let bIndex = graph.nodeToIndex["B"]!
        let cIndex = graph.nodeToIndex["C"]!

        #expect(graph.reverseAdjacency[bIndex].contains(aIndex))
        #expect(graph.reverseAdjacency[cIndex].contains(aIndex))
        #expect(graph.reverseAdjacency[cIndex].contains(bIndex))
        #expect(graph.reverseAdjacency[cIndex].count == 2)
        #expect(graph.reverseAdjacency[aIndex].isEmpty)
    }

    @Test("Root indices correctly identified")
    func rootIndices() {
        let graph = DenseGraph(nodeIds: ["A", "B", "C"], edges: [], rootIds: ["A", "C"])

        #expect(graph.roots.count == 2)
        #expect(graph.roots.contains(graph.nodeToIndex["A"]!))
        #expect(graph.roots.contains(graph.nodeToIndex["C"]!))
    }

    @Test("Invalid edges are skipped")
    func invalidEdgesSkipped() {
        let graph = DenseGraph(
            nodeIds: ["A", "B"],
            edges: [("A", "B"), ("A", "X"), ("Y", "B"), ("X", "Y")],
            rootIds: []
        )

        #expect(graph.edgeCount == 1)
    }

    @Test("ToNodeIds converts indices back to strings")
    func toNodeIds() {
        let graph = DenseGraph(nodeIds: ["A", "B", "C"], edges: [], rootIds: [])
        #expect(graph.toNodeIds([0, 2]) == ["A", "C"])
    }

    @Test("TotalOutEdges calculates correctly")
    func totalOutEdges() {
        let graph = DenseGraph(
            nodeIds: ["A", "B", "C"],
            edges: [("A", "B"), ("A", "C"), ("B", "C")],
            rootIds: []
        )

        let aIndex = graph.nodeToIndex["A"]!
        let bIndex = graph.nodeToIndex["B"]!

        #expect(graph.totalOutEdges(from: [aIndex]) == 2)
        #expect(graph.totalOutEdges(from: [bIndex]) == 1)
        #expect(graph.totalOutEdges(from: [aIndex, bIndex]) == 3)
    }

    @Test("Sequential BFS finds all reachable nodes")
    func sequentialBFS() {
        let graph = DenseGraph(
            nodeIds: ["A", "B", "C", "D", "E"],
            edges: [("A", "B"), ("B", "C"), ("C", "D")],
            rootIds: ["A"]
        )

        let reachable = graph.computeReachableSequential()

        #expect(reachable.count == 4)
        #expect(!reachable.contains(graph.nodeToIndex["E"]!))
    }

    @Test("Sequential BFS with multiple roots")
    func sequentialBFSMultipleRoots() {
        let graph = DenseGraph(
            nodeIds: ["A", "B", "C", "D"],
            edges: [("A", "B"), ("C", "D")],
            rootIds: ["A", "C"]
        )

        #expect(graph.computeReachableSequential().count == 4)
    }

    @Test("Sequential BFS handles cycles")
    func sequentialBFSCycles() {
        let graph = DenseGraph(
            nodeIds: ["A", "B", "C"],
            edges: [("A", "B"), ("B", "C"), ("C", "A")],
            rootIds: ["A"]
        )

        #expect(graph.computeReachableSequential().count == 3)
    }

    @Test("ParallelBFS matches sequential reference on a cyclic graph")
    func parallelMatchesSequentialOnCyclicGraph() async {
        //   a → b → c → b   (back edge)
        //       ↓
        //       d
        let graph = DenseGraph(
            nodeIds: ["a", "b", "c", "d"],
            edges: [("a", "b"), ("b", "c"), ("c", "b"), ("b", "d")],
            rootIds: ["a"]
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
            nodeIds: ["a", "b", "c", "x", "y", "z"],
            edges: [("a", "b"), ("b", "c"), ("x", "y"), ("y", "z")],
            rootIds: ["a"]
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
