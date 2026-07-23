//  Lifted from SwiftStaticAnalysis (MIT) — Algorithms/DirectionOptimizingBFS.swift.

// MARK: - DirectionOptimizingBFS

/// Direction-switching predicates for hybrid top-down / bottom-up BFS
/// (Beamer, Asanovic, Patterson 2012, "Direction-Optimizing Breadth-First
/// Search").
///
/// Frontier-density-driven BFS switches between top-down expansion (push
/// neighbors of frontier nodes) and bottom-up traversal (pull frontier-
/// adjacent neighbors of unvisited nodes) based on the current frontier's
/// share of remaining edges.
enum DirectionOptimizingBFS {
    /// Switch from top-down to bottom-up traversal when the frontier would
    /// touch most of the remaining edges.
    ///
    /// - Returns: `true` when `frontierEdges * alpha > remainingEdges`,
    ///   `false` if `remainingEdges == 0` (nothing left to traverse).
    @inlinable
    static func shouldSwitchToBottomUp(
        frontierEdges: Int,
        remainingEdges: Int,
        alpha: Int
    ) -> Bool {
        guard remainingEdges > 0 else { return false }
        return frontierEdges * alpha > remainingEdges
    }

    /// Switch back from bottom-up to top-down when the frontier becomes
    /// small relative to the node count.
    ///
    /// - Returns: `true` when `frontierSize * beta < nodeCount`.
    @inlinable
    static func shouldSwitchToTopDown(
        frontierSize: Int,
        nodeCount: Int,
        beta: Int
    ) -> Bool {
        frontierSize * beta < nodeCount
    }
}
