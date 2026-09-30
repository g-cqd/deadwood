//  New in deadwood: reachability by build level. A release build compiles
//  production code; a debug build adds `#if DEBUG` code; previews add
//  preview code. Each edge and root carries the lowest level whose code
//  draws it, and one breadth-first search, widened level by level, finds
//  the lowest level at which each declaration becomes reachable.

// MARK: - LeveledEdges

/// The dependency edges with the region level of the code drawing each one.
struct LeveledEdges: Sendable {
    /// Targets of each source node, indexed by node.
    private(set) var targets: ContiguousArray<[Int32]>
    /// Level of each edge, aligned with `targets`.
    private(set) var levels: ContiguousArray<[UInt8]>

    init(nodeCount: Int) {
        targets = ContiguousArray(repeating: [], count: nodeCount)
        levels = ContiguousArray(repeating: [], count: nodeCount)
    }

    var nodeCount: Int { targets.count }

    mutating func add(source: Int32, targets newTargets: [Int32], levels newLevels: [UInt8]) {
        let index = Int(source)
        guard index >= 0, index < targets.count else { return }
        for (target, level) in zip(newTargets, newLevels) where target >= 0 && Int(target) < targets.count {
            targets[index].append(target)
            levels[index].append(level)
        }
    }
}

// MARK: - LeveledReachability

enum LeveledReachability {
    /// Level value of a node no root reaches at any level.
    static let unreached = UInt8.max

    /// The lowest level at which each node is reachable, or ``unreached``.
    ///
    /// Invariant: when level *L* ends, every node reachable from a root of
    /// level ≤ *L* through edges of level ≤ *L* is marked, with the lowest
    /// such level. An edge above the current level is set aside in the
    /// pending list of its own level and followed when that level starts,
    /// so each node is dequeued once and each edge looked at twice at most.
    /// - Complexity: O(V + E) time, O(V) extra space beyond the pending
    ///   lists, which hold at most E entries.
    static func levels(
        of edges: LeveledEdges,
        roots: [(node: Int32, level: UInt8)],
        levelCount: Int
    ) -> [UInt8] {
        var reachedAt = [UInt8](repeating: unreached, count: edges.nodeCount)
        var pending = [[Int32]](repeating: [], count: levelCount)
        for root in roots where Int(root.level) < levelCount && Int(root.node) < edges.nodeCount {
            pending[Int(root.level)].append(root.node)
        }
        for level in 0..<levelCount {
            let current = UInt8(level)
            var queue: [Int32] = []
            for node in pending[level] where reachedAt[Int(node)] == unreached {
                reachedAt[Int(node)] = current
                queue.append(node)
            }
            pending[level] = []
            var head = 0
            while head < queue.count {
                let node = Int(queue[head])
                head += 1
                let targets = edges.targets[node]
                let edgeLevels = edges.levels[node]
                for (target, edgeLevel) in zip(targets, edgeLevels) {
                    if edgeLevel <= current {
                        if reachedAt[Int(target)] == unreached {
                            reachedAt[Int(target)] = current
                            queue.append(target)
                        }
                    } else if Int(edgeLevel) < levelCount {
                        pending[Int(edgeLevel)].append(target)
                    }
                }
            }
        }
        return reachedAt
    }
}
