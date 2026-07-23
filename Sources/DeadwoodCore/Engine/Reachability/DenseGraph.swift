//  Lifted from SwiftStaticAnalysis (MIT) — UnusedCodeDetector/Reachability/DenseGraph.swift.
//  Changes during the lift: `BitArray` (swift-collections) replaced by
//  `[Bool]`, the sequential BFS queue rides `ArrayQueue`, and the debug
//  statistics extension is trimmed.

// MARK: - DenseGraph

/// Dense graph representation optimized for BFS.
///
/// Converts string-based node IDs to contiguous integers (0..<nodeCount)
/// for cache-efficient array access during traversal: no string hashing in
/// the inner loop, integer indices map directly to bitmap positions.
struct DenseGraph: Sendable {
    /// Map from original node ID to dense integer index.
    let nodeToIndex: [String: Int]

    /// Map from dense index back to original node ID.
    let indexToNode: [String]

    /// Adjacency list using dense indices.
    let adjacency: [[Int]]

    /// Reverse adjacency for bottom-up BFS.
    let reverseAdjacency: [[Int]]

    /// Root node indices.
    let roots: [Int]

    /// Total number of edges.
    let edgeCount: Int

    /// Out-degree for each node.
    let outDegrees: [Int]

    /// Create a dense graph from node IDs, edges, and roots.
    init(
        nodeIds: [String],
        edges: [(from: String, to: String)],
        rootIds: Set<String>
    ) {
        var nodeToIndex: [String: Int] = [:]
        nodeToIndex.reserveCapacity(nodeIds.count)
        for (index, nodeId) in nodeIds.enumerated() {
            nodeToIndex[nodeId] = index
        }

        self.nodeToIndex = nodeToIndex
        self.indexToNode = nodeIds

        var adjacency: [[Int]] = Array(repeating: [], count: nodeIds.count)
        var reverseAdjacency: [[Int]] = Array(repeating: [], count: nodeIds.count)
        var validEdgeCount = 0

        for (from, to) in edges {
            guard let fromIndex = nodeToIndex[from],
                let toIndex = nodeToIndex[to]
            else {
                continue  // Skip edges with unknown nodes.
            }

            adjacency[fromIndex].append(toIndex)
            reverseAdjacency[toIndex].append(fromIndex)
            validEdgeCount += 1
        }

        self.adjacency = adjacency
        self.reverseAdjacency = reverseAdjacency
        self.edgeCount = validEdgeCount
        self.roots = rootIds.compactMap { nodeToIndex[$0] }
        self.outDegrees = adjacency.map(\.count)
    }

    /// Total number of nodes.
    var nodeCount: Int { indexToNode.count }

    /// Whether the graph is empty.
    var isEmpty: Bool { nodeCount == 0 }

    /// Convert dense indices back to original node IDs.
    func toNodeIds(_ indices: Set<Int>) -> Set<String> {
        Set(indices.map { indexToNode[$0] })
    }

    /// Total edges out of a set of nodes (direction-optimizing heuristic).
    func totalOutEdges(from nodes: [Int]) -> Int {
        nodes.reduce(0) { $0 + outDegrees[$1] }
    }

    /// Remaining unvisited edges (approximate).
    func remainingEdges(visited: AtomicBitmap) -> Int {
        var count = 0
        for index in 0..<nodeCount where !visited.test(index) {
            count += outDegrees[index]
        }
        return count
    }
}

// MARK: - DenseGraph + Sequential BFS

extension DenseGraph {
    /// Sequential BFS reference implementation (also the small-graph fast
    /// path for `ParallelBFS`).
    func computeReachableSequential() -> Set<Int> {
        guard !roots.isEmpty else { return [] }

        var visited = [Bool](repeating: false, count: nodeCount)
        var queue = ArrayQueue<Int>()
        queue.reserveCapacity(nodeCount)

        for root in roots where !visited[root] {
            visited[root] = true
            queue.append(root)
        }

        while let current = queue.popFirst() {
            for neighbor in adjacency[current] where !visited[neighbor] {
                visited[neighbor] = true
                queue.append(neighbor)
            }
        }

        var result = Set<Int>()
        for index in 0..<nodeCount where visited[index] {
            result.insert(index)
        }
        return result
    }
}
