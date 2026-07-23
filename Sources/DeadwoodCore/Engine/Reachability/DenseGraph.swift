//  Lifted from SwiftStaticAnalysis (MIT) — UnusedCodeDetector/Reachability/DenseGraph.swift.
//  Changes during the lift: `BitArray` (swift-collections) replaced by
//  `[Bool]`, the sequential BFS queue rides `ArrayQueue`, and the debug
//  statistics extension is trimmed. Node ids are dense declaration indices
//  end to end now, so the String→Int re-mapping (`nodeToIndex`/
//  `indexToNode`/`toNodeIds`) is gone entirely.

// MARK: - DenseGraph

/// Dense graph representation optimized for BFS.
///
/// Node identity is the declaration's corpus index (0..<nodeCount): integer
/// indices map directly to array slots and bitmap positions, with no
/// hashing in the traversal loops.
struct DenseGraph: Sendable {
    /// Adjacency list indexed by node.
    let adjacency: [[Int]]

    /// Reverse adjacency for bottom-up BFS.
    let reverseAdjacency: [[Int]]

    /// Root node indices.
    let roots: [Int]

    /// Total number of edges.
    let edgeCount: Int

    /// Out-degree for each node.
    let outDegrees: [Int]

    /// Snapshot an adjacency structure (the reachability actor's state).
    init(adjacency source: ContiguousArray<[Int32]>, roots rootIndices: Set<Int32>) {
        let count = source.count
        var adjacency: [[Int]] = []
        adjacency.reserveCapacity(count)
        var reverseAdjacency: [[Int]] = Array(repeating: [], count: count)
        var edgeCount = 0

        for (from, targets) in source.enumerated() {
            var forward: [Int] = []
            forward.reserveCapacity(targets.count)
            for target in targets {
                let to = Int(target)
                forward.append(to)
                reverseAdjacency[to].append(from)
            }
            edgeCount += forward.count
            adjacency.append(forward)
        }

        self.adjacency = adjacency
        self.reverseAdjacency = reverseAdjacency
        self.edgeCount = edgeCount
        self.roots = rootIndices.compactMap { index in
            let value = Int(index)
            return value >= 0 && value < count ? value : nil
        }
        self.outDegrees = adjacency.map(\.count)
    }

    /// Build from an explicit edge list (test convenience). Out-of-range
    /// endpoints are skipped defensively.
    init(nodeCount: Int, edges: [(from: Int32, to: Int32)], roots rootIndices: Set<Int32>) {
        var source = ContiguousArray<[Int32]>(repeating: [], count: nodeCount)
        for edge in edges {
            guard edge.from >= 0, Int(edge.from) < nodeCount,
                edge.to >= 0, Int(edge.to) < nodeCount
            else { continue }
            source[Int(edge.from)].append(edge.to)
        }
        self.init(adjacency: source, roots: rootIndices)
    }

    /// Total number of nodes.
    var nodeCount: Int { adjacency.count }

    /// Whether the graph is empty.
    var isEmpty: Bool { nodeCount == 0 }

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
