//  Lifted from SwiftStaticAnalysis (MIT) — UnusedCodeDetector/Reachability/ReachabilityGraph.swift.
//  Changes during the lift:
//  - root detection moved to `RootDetector` (shared with simple mode) and
//    made context-aware; the doc-comment attribute fallback is gone.
//  - `Deque`-based path finding, the report generator, and the per-edge
//    mutators are trimmed (deadwood only builds once and queries once).
//  - node identity is the declaration's dense corpus index (`Int32`), not a
//    "file:line:name" string: no id interpolation at construction and no
//    string hashing on edge insert, flatten, or projection. Unreachable
//    results are indices; callers map back through the declaration array.

// MARK: - DependencyEdge

/// An edge in the reachability graph. Endpoints are dense declaration
/// indices (the declaration's position in the aggregated corpus array).
struct DependencyEdge: Hashable, Sendable {
    /// Source declaration index.
    let from: Int32

    /// Target declaration index.
    let to: Int32

    /// Kind of dependency.
    let kind: DependencyKind

    init(from: Int32, to: Int32, kind: DependencyKind) {
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
/// adjacency state. Nodes are implicit: every declaration index in
/// `0..<nodeCount` is a node.
actor ReachabilityGraph {
    /// Number of declarations (nodes are `0..<nodeCount`).
    private(set) var nodeCount = 0

    /// Adjacency lists indexed by declaration index.
    private var adjacency: ContiguousArray<[Int32]> = []

    /// Deduplication set for inserted (from, to) pairs, packed into one
    /// 64-bit key so batch insert never hashes more than an integer.
    private var seenEdges: Set<UInt64> = []

    /// Root declaration indices (entry points).
    private var roots: Set<Int32> = []

    /// Cache of reachable indices.
    private var reachableCache: Set<Int>?

    /// Cached dense projection; invalidated on every mutation.
    private var denseGraphCache: DenseGraph?

    init() {}

    // MARK: - Building the graph

    /// Size the graph for `count` declarations (indices `0..<count`) with
    /// the given root set, clearing any previous state. Out-of-range roots
    /// are dropped defensively.
    func prepare(declarationCount count: Int, roots rootIndices: Set<Int32> = []) {
        nodeCount = count
        adjacency = ContiguousArray(repeating: [], count: count)
        seenEdges = []
        roots = rootIndices.filter { $0 >= 0 && Int($0) < count }
        invalidateCaches()
    }

    /// Add multiple edges in a single batch (one actor hop per worker).
    /// Duplicate (from, to) pairs are dropped; out-of-range endpoints are
    /// ignored defensively.
    func addEdges(_ newEdges: [DependencyEdge]) {
        guard !newEdges.isEmpty else { return }

        for edge in newEdges {
            guard edge.from >= 0, Int(edge.from) < nodeCount,
                edge.to >= 0, Int(edge.to) < nodeCount
            else { continue }
            let key =
                (UInt64(UInt32(bitPattern: edge.from)) << 32)
                | UInt64(UInt32(bitPattern: edge.to))
            if seenEdges.insert(key).inserted {
                adjacency[Int(edge.from)].append(edge.to)
            }
        }

        invalidateCaches()
    }

    private func invalidateCaches() {
        reachableCache = nil
        denseGraphCache = nil
    }

    // MARK: - Root detection

    /// Size the graph for the declarations and mark roots per the detector.
    func detectRoots(
        declarations: [Declaration],
        context: CorpusContext,
        configuration: RootDetectionConfiguration = .default
    ) {
        let detector = RootDetector(configuration: configuration)
        var rootIndices: Set<Int32> = []
        for (index, declaration) in declarations.enumerated()
        where detector.rootReason(for: declaration, context: context) != nil {
            rootIndices.insert(Int32(index))
        }
        prepare(declarationCount: declarations.count, roots: rootIndices)
    }

    // MARK: - Reachability

    /// Compute all reachable declaration indices from the root set
    /// (sequential BFS over the dense projection).
    func computeReachable() -> Set<Int> {
        if let cached = reachableCache {
            return cached
        }

        let reachable = denseGraph().computeReachableSequential()
        reachableCache = reachable
        return reachable
    }

    /// All unreachable declaration indices, ascending.
    func computeUnreachable() -> [Int32] {
        let reachable = computeReachable()
        return unreachableIndices(reachable: reachable)
    }

    /// Compute reachable indices using direction-optimizing parallel BFS.
    func computeReachableParallel(
        configuration: ParallelBFS.Configuration = .default
    ) async -> Set<Int> {
        await ParallelBFS.computeReachable(graph: denseGraph(), configuration: configuration)
    }

    /// Reachable indices from an EXPLICIT root set over the same edges —
    /// production mode's second pass (without test roots). Uncached: the
    /// root set is the caller's, not the graph's.
    func computeReachable(fromRoots rootIndices: Set<Int32>) -> Set<Int> {
        denseGraph().computeReachableSequential(from: rootIndices.map(Int.init))
    }

    private func unreachableIndices(reachable: Set<Int>) -> [Int32] {
        var unreachable: [Int32] = []
        unreachable.reserveCapacity(max(0, nodeCount - reachable.count))
        for index in 0..<nodeCount where !reachable.contains(index) {
            unreachable.append(Int32(index))
        }
        return unreachable
    }

    // MARK: - Dense projection

    /// Lazily build (and cache) the dense projection of the graph: an
    /// immutable snapshot of the adjacency the BFS backends can consume
    /// outside the actor.
    private func denseGraph() -> DenseGraph {
        if let cached = denseGraphCache {
            return cached
        }
        let dense = DenseGraph(adjacency: adjacency, roots: roots)
        denseGraphCache = dense
        return dense
    }
}
