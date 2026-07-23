//  Lifted from SwiftStaticAnalysis (MIT) — UnusedCodeDetector/Reachability/ReachabilityGraph.swift.
//  Changes during the lift:
//  - root detection moved to `RootDetector` (shared with simple mode) and
//    made context-aware; the doc-comment attribute fallback is gone.
//  - `Deque`-based path finding, the report generator, and the per-edge
//    mutators are trimmed (deadwood only builds once and queries once).

// MARK: - DeclarationNode

/// A node in the reachability graph representing a declaration.
struct DeclarationNode: Hashable, Sendable {
    /// Unique identifier for this node (file:line:name).
    let id: String

    /// The declaration this node represents.
    let declaration: Declaration

    /// Whether this is a root node (entry point).
    let isRoot: Bool

    /// Reason this is a root (if applicable).
    let rootReason: RootReason?

    init(declaration: Declaration, isRoot: Bool = false, rootReason: RootReason? = nil) {
        id = "\(declaration.location.file):\(declaration.location.line):\(declaration.name)"
        self.declaration = declaration
        self.isRoot = isRoot
        self.rootReason = rootReason
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - DependencyEdge

/// An edge in the reachability graph representing a dependency.
struct DependencyEdge: Hashable, Sendable {
    /// Source node ID.
    let from: String

    /// Target node ID.
    let to: String

    /// Kind of dependency.
    let kind: DependencyKind

    init(from: String, to: String, kind: DependencyKind) {
        self.from = from
        self.to = to
        self.kind = kind
    }
}

// MARK: - DependencyKind

/// Kinds of dependencies between declarations.
enum DependencyKind: String, Sendable {
    /// Direct function/method call.
    case call

    /// Type reference (variable type, parameter type, return type).
    case typeReference

    /// Inheritance or protocol conformance.
    case inheritance

    /// Property access.
    case propertyAccess

    /// Generic constraint.
    case genericConstraint

    /// Key path reference.
    case keyPath

    /// Protocol requirement kept alive by its protocol, or witness kept
    /// alive by its requirement.
    case protocolRequirement
}

// MARK: - ReachabilityGraph

/// Graph for analyzing code reachability from entry points.
///
/// An actor: the extractor inserts edge batches from parallel workers, and
/// the actor model gives compile-time data-race safety for the mutable
/// adjacency state.
actor ReachabilityGraph {
    /// All nodes in the graph.
    private var nodes: [String: DeclarationNode] = [:]

    /// Adjacency list (edges from each node).
    private var edges: [String: Set<DependencyEdge>] = [:]

    /// Root nodes (entry points).
    private var roots: Set<String> = []

    /// Cache of reachable nodes.
    private var reachableCache: Set<String>?

    /// Cached dense projection; invalidated on every mutation.
    private var denseGraphCache: DenseGraph?

    init() {}

    /// Total number of nodes.
    var nodeCount: Int {
        nodes.count
    }

    // MARK: - Building the graph

    /// Add a declaration node to the graph.
    func addNode(
        _ declaration: Declaration,
        isRoot: Bool = false,
        rootReason: RootReason? = nil
    ) {
        let node = DeclarationNode(declaration: declaration, isRoot: isRoot, rootReason: rootReason)
        nodes[node.id] = node

        if isRoot {
            roots.insert(node.id)
        }

        reachableCache = nil
        denseGraphCache = nil
    }

    /// Add multiple edges in a single batch (one actor hop per worker).
    func addEdges(_ newEdges: [DependencyEdge]) {
        guard !newEdges.isEmpty else { return }

        for edge in newEdges {
            edges[edge.from, default: []].insert(edge)
        }

        reachableCache = nil
        denseGraphCache = nil
    }

    // MARK: - Root detection

    /// Add every declaration as a node, marking roots per the detector.
    func detectRoots(
        declarations: [Declaration],
        context: CorpusContext,
        configuration: RootDetectionConfiguration = .default
    ) {
        let detector = RootDetector(configuration: configuration)
        for declaration in declarations {
            if let reason = detector.rootReason(for: declaration, context: context) {
                addNode(declaration, isRoot: true, rootReason: reason)
            } else {
                addNode(declaration, isRoot: false)
            }
        }
    }

    // MARK: - Reachability

    /// Compute all reachable node IDs from the root set (sequential BFS
    /// over the dense projection).
    func computeReachable() -> Set<String> {
        if let cached = reachableCache {
            return cached
        }

        let dense = denseGraph()
        let reachable = dense.toNodeIds(dense.computeReachableSequential())

        reachableCache = reachable
        return reachable
    }

    /// All unreachable nodes.
    func computeUnreachable() -> [DeclarationNode] {
        let reachable = computeReachable()
        return nodes.values.filter { !reachable.contains($0.id) }
    }

    /// Compute reachable node IDs using direction-optimizing parallel BFS.
    func computeReachableParallel(
        configuration: ParallelBFS.Configuration = .default
    ) async -> Set<String> {
        let dense = denseGraph()
        let reachableIndices = await ParallelBFS.computeReachable(
            graph: dense,
            configuration: configuration
        )
        return dense.toNodeIds(reachableIndices)
    }

    /// All unreachable nodes, via parallel BFS.
    func computeUnreachableParallel(
        configuration: ParallelBFS.Configuration = .default
    ) async -> [DeclarationNode] {
        let reachable = await computeReachableParallel(configuration: configuration)
        return nodes.values.filter { !reachable.contains($0.id) }
    }

    // MARK: - Dense projection

    /// Lazily build (and cache) the dense projection of the graph.
    private func denseGraph() -> DenseGraph {
        if let cached = denseGraphCache {
            return cached
        }
        let nodeIds = Array(nodes.keys)
        var flatEdges: [(from: String, to: String)] = []
        flatEdges.reserveCapacity(edges.values.reduce(0) { $0 + $1.count })
        for (from, outgoing) in edges {
            for edge in outgoing {
                flatEdges.append((from, edge.to))
            }
        }
        let dense = DenseGraph(nodeIds: nodeIds, edges: flatEdges, rootIds: roots)
        denseGraphCache = dense
        return dense
    }
}
