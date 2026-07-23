//  Lifted from SwiftStaticAnalysis (MIT) — Algorithms/ParallelFrontierExpansion.swift.
//  `chunks(ofCount:)` (swift-algorithms) replaced by the CollectionShims
//  helpers.

// MARK: - ParallelFrontierExpansion

/// Generic parallel frontier expansion for BFS-like graph traversals over
/// any adjacency source with atomic visited tracking.
enum ParallelFrontierExpansion {
    /// Expand a frontier in parallel using chunked TaskGroup processing
    /// (top-down BFS: each frontier node expands to its neighbors).
    ///
    /// - Parameters:
    ///   - frontier: Current frontier nodes to expand.
    ///   - maxConcurrency: Maximum concurrent tasks.
    ///   - getNeighbors: Closure returning neighbors for a node.
    ///   - testAndSetVisited: Atomic closure, true when newly visited.
    /// - Returns: Next frontier of newly discovered nodes.
    static func expandParallel(
        frontier: [Int],
        maxConcurrency: Int,
        getNeighbors: @escaping @Sendable (Int) -> [Int],
        testAndSetVisited: @escaping @Sendable (Int) -> Bool
    ) async -> [Int] {
        let chunkSize = max(1, frontier.count / max(1, maxConcurrency))

        return await withTaskGroup(of: [Int].self) { group in
            for chunk in frontier.chunkedSlices(chunkSize: chunkSize) {
                group.addTask {
                    var localNext: [Int] = []
                    var processedNodes = 0

                    for node in chunk {
                        for neighbor in getNeighbors(node) where testAndSetVisited(neighbor) {
                            localNext.append(neighbor)
                        }

                        processedNodes += 1
                        if await TaskCooperation.checkpoint(iteration: processedNodes) {
                            break
                        }
                    }
                    return localNext
                }
            }

            var result: [Int] = []
            for await partial in group {
                result.append(contentsOf: partial)
                // Propagate cancellation to peer tasks once any worker
                // observes it; siblings would otherwise finish their full
                // chunk before the group can return.
                if Task.isCancelled {
                    group.cancelAll()
                }
            }
            return result
        }
    }
}
