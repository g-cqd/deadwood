//  Lifted from SwiftStaticAnalysis (MIT) — UnusedCodeDetector/Reachability/ParallelBFS.swift.
//  Changes during the lift: `chunks(ofCount:)` replaced by CollectionShims,
//  `BitArray` frontier replaced by `[Bool]`, and the stats-collecting
//  variant trimmed.

import Foundation

// MARK: - ParallelBFS

/// Direction-optimizing parallel BFS (Beamer, Asanovic, Patterson 2012).
///
/// Combines two strategies, switching dynamically on frontier density:
///
/// 1. **Top-down**: frontier nodes expand outward to neighbors. Efficient
///    while the frontier is small relative to the graph.
/// 2. **Bottom-up**: unvisited nodes check whether any predecessor is in
///    the frontier. Efficient when the frontier is large (avoids redundant
///    edge checks).
///
/// Thread safety: `AtomicBitmap` provides lock-free visited tracking; all
/// other shared state is immutable.
enum ParallelBFS {
    // MARK: - Configuration

    /// Configuration for parallel BFS execution. Parameters are clamped to
    /// valid ranges (alpha/beta per Beamer et al. recommendations).
    struct Configuration: Sendable {
        /// Default configuration based on Beamer et al. recommendations.
        static let `default` = Configuration()

        /// Threshold for switching top-down → bottom-up.
        var alpha: Int

        /// Threshold for switching bottom-up → top-down.
        var beta: Int

        /// Minimum graph size to use parallel BFS; below it, sequential.
        var minParallelSize: Int

        /// Maximum concurrent tasks.
        var maxConcurrency: Int

        init(
            alpha: Int = 14,
            beta: Int = 24,
            minParallelSize: Int = 1000,
            maxConcurrency: Int? = nil
        ) {
            self.alpha = max(1, min(alpha, 100))
            self.beta = max(1, min(beta, 100))
            self.minParallelSize = max(1, minParallelSize)

            let processorCount = ProcessInfo.processInfo.activeProcessorCount
            let requestedConcurrency = maxConcurrency ?? processorCount
            self.maxConcurrency = max(1, min(requestedConcurrency, processorCount))
        }
    }

    // MARK: - Main entry point

    /// Compute reachable node indices using direction-optimizing BFS.
    static func computeReachable(
        graph: DenseGraph,
        configuration: Configuration = .default
    ) async -> Set<Int> {
        guard !graph.isEmpty, !graph.roots.isEmpty else {
            return []
        }

        // Sequential fast path for small graphs (overhead dominates).
        if graph.nodeCount < configuration.minParallelSize {
            return graph.computeReachableSequential()
        }

        let visited = AtomicBitmap(size: graph.nodeCount)
        var frontier: [Int] = []
        frontier.reserveCapacity(graph.roots.count)

        for root in graph.roots where visited.testAndSet(root) {
            frontier.append(root)
        }

        var useBottomUp = false

        while !frontier.isEmpty {
            let frontierEdges = graph.totalOutEdges(from: frontier)
            // Key heuristic per Beamer et al.: compare against REMAINING
            // (unvisited) edges, not total edges.
            let remainingEdges = graph.remainingEdges(visited: visited)

            if !useBottomUp {
                if DirectionOptimizingBFS.shouldSwitchToBottomUp(
                    frontierEdges: frontierEdges,
                    remainingEdges: remainingEdges,
                    alpha: configuration.alpha
                ) {
                    useBottomUp = true
                }
            } else {
                if DirectionOptimizingBFS.shouldSwitchToTopDown(
                    frontierSize: frontier.count,
                    nodeCount: graph.nodeCount,
                    beta: configuration.beta
                ) {
                    useBottomUp = false
                }
            }

            if useBottomUp {
                frontier = await bottomUpStep(
                    frontier: frontier,
                    graph: graph,
                    visited: visited,
                    maxConcurrency: configuration.maxConcurrency
                )
            } else {
                frontier = await topDownStep(
                    frontier: frontier,
                    graph: graph,
                    visited: visited,
                    maxConcurrency: configuration.maxConcurrency
                )
            }
        }

        return Set(visited.allSetBits())
    }

    // MARK: - Top-down step

    /// Frontier expands outward to neighbors; new nodes join the next
    /// frontier.
    private static func topDownStep(
        frontier: [Int],
        graph: DenseGraph,
        visited: AtomicBitmap,
        maxConcurrency: Int
    ) async -> [Int] {
        // Small frontiers: sequential beats task spawn overhead.
        if frontier.count < maxConcurrency * 2 {
            return topDownStepSequential(frontier: frontier, graph: graph, visited: visited)
        }

        return await ParallelFrontierExpansion.expandParallel(
            frontier: frontier,
            maxConcurrency: maxConcurrency,
            getNeighbors: { graph.adjacency[$0] },
            testAndSetVisited: { visited.testAndSet($0) }
        )
    }

    private static func topDownStepSequential(
        frontier: [Int],
        graph: DenseGraph,
        visited: AtomicBitmap
    ) -> [Int] {
        var nextFrontier: [Int] = []

        for node in frontier {
            for neighbor in graph.adjacency[node] where visited.testAndSet(neighbor) {
                nextFrontier.append(neighbor)
            }
        }

        return nextFrontier
    }

    // MARK: - Bottom-up step

    /// Unvisited nodes join the frontier when any predecessor is in it.
    /// The frontier bitmap is a plain `[Bool]`: written single-threaded
    /// here, only read during the parallel phase.
    private static func bottomUpStep(
        frontier: [Int],
        graph: DenseGraph,
        visited: AtomicBitmap,
        maxConcurrency: Int
    ) async -> [Int] {
        var frontierBits = [Bool](repeating: false, count: graph.nodeCount)
        for index in frontier {
            frontierBits[index] = true
        }
        let frontierBitmap = frontierBits

        let unvisitedCount = graph.nodeCount - visited.popCount
        if unvisitedCount < maxConcurrency * 2 {
            return bottomUpStepSequential(
                nodeCount: graph.nodeCount,
                frontierBitmap: frontierBitmap,
                graph: graph,
                visited: visited
            )
        }

        let chunkSize = max(1, graph.nodeCount / maxConcurrency)

        return await withTaskGroup(of: [Int].self) { group in
            for chunk in chunkedRanges(count: graph.nodeCount, chunkSize: chunkSize) {
                group.addTask {
                    var localNext: [Int] = []

                    for node in chunk {
                        guard !visited.test(node) else { continue }

                        for predecessor in graph.reverseAdjacency[node]
                        where frontierBitmap[predecessor] {
                            if visited.testAndSet(node) {
                                localNext.append(node)
                            }
                            break  // One frontier parent suffices.
                        }
                    }
                    return localNext
                }
            }

            var nextFrontier: [Int] = []
            for await partial in group {
                nextFrontier.append(contentsOf: partial)
            }
            return nextFrontier
        }
    }

    private static func bottomUpStepSequential(
        nodeCount: Int,
        frontierBitmap: [Bool],
        graph: DenseGraph,
        visited: AtomicBitmap
    ) -> [Int] {
        var nextFrontier: [Int] = []

        for node in 0..<nodeCount {
            guard !visited.test(node) else { continue }

            for predecessor in graph.reverseAdjacency[node] where frontierBitmap[predecessor] {
                if visited.testAndSet(node) {
                    nextFrontier.append(node)
                }
                break
            }
        }

        return nextFrontier
    }
}
