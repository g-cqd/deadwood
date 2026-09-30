//  New in deadwood: dead code comes in chains. A declaration only dead code
//  uses is dead too; reporting it only once its user is deleted takes one
//  run per link. Groups gather each chain under the declaration nothing
//  names at all, and a dead cycle under its first member.

// MARK: - DeadCodeGroups

/// The dead declarations arranged in groups: each group has a root, and
/// every other member is used only by dead code of its group.
struct DeadCodeGroups: Sendable {
    /// The group root of each dead node; a root maps to itself.
    private(set) var rootOf: [Int: Int] = [:]
    /// The dead node through which each non-root member was reached first.
    private(set) var parentOf: [Int: Int] = [:]
    /// The dead nodes using each dead node.
    private(set) var users: [Int: [Int]] = [:]
    /// Roots of groups that no unused declaration starts: dead cycles.
    private(set) var cycleRoots: Set<Int> = []
    /// Every dead node in the order the groups were walked: a root before
    /// its members, a member after its parent.
    private(set) var order: [Int] = []
    /// How many members each root's group has, the root excluded.
    private(set) var memberCount: [Int: Int] = [:]

    /// Group `dead` (ascending node ids) along `successors`, the dead nodes
    /// each dead node uses.
    ///
    /// A root is a dead node no dead node uses. Each root, in ascending
    /// order, claims the members it reaches that no earlier root claimed.
    /// Nodes left unclaimed are only used within cycles nothing else
    /// reaches; the smallest one becomes that group's root.
    /// - Complexity: O(V + E) over the dead nodes and the edges between them.
    init(dead: [Int], successors: [Int: [Int]]) {
        for node in dead {
            for target in successors[node] ?? [] where target != node {
                users[target, default: []].append(node)
            }
        }
        for node in dead where users[node] == nil {
            claim(from: node, successors: successors)
        }
        for node in dead where rootOf[node] == nil {
            cycleRoots.insert(node)
            claim(from: node, successors: successors)
        }
    }

    private mutating func claim(from root: Int, successors: [Int: [Int]]) {
        rootOf[root] = root
        order.append(root)
        var queue = [root]
        var head = 0
        while head < queue.count {
            let node = queue[head]
            head += 1
            for target in successors[node] ?? [] where rootOf[target] == nil {
                rootOf[target] = root
                parentOf[target] = node
                memberCount[root, default: 0] += 1
                order.append(target)
                queue.append(target)
            }
        }
    }
}
