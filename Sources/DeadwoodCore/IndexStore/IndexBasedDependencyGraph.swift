//  Lifted from SwiftStaticAnalysis (MIT) —
//  UnusedCodeDetector/IndexStore/IndexBasedDependencyGraph.swift.
//  Changes during the lift:
//  - Whole file gated behind `#if canImport(IndexStoreDB)`.
//  - The BFS no longer carries its own `Deque`/`Set<String>` walk or a
//    private `DenseGraph`; it projects the USR-keyed adjacency onto deadwood's
//    shared `DenseGraph` (integer indices, bit-packed visited set) exactly
//    like the syntax reachability graph, then maps the reachable indices back
//    to USRs. `import Collections` is therefore gone.
//  - Root detection is removed. deadwood owns a far richer `RootDetector`
//    (SwiftUI, @objc, operators, Codable, external witnesses, public API); the
//    bridge supplies the root USRs, so this graph only tracks edges and answers
//    "reachable from these roots". `Mutex` is gone too — the graph is built and
//    queried on one synchronous stretch inside the bridge, never shared.
//  - `IndexGraphReport`/`generateReport` and the SwiftUI/objc root config
//    flags (unused by SSA's own root detection) are trimmed.

#if canImport(IndexStoreDB)
    import Foundation
    import IndexStoreDB

    // MARK: - IndexSymbolNode

    /// A node in the dependency graph representing a symbol from the index.
    struct IndexSymbolNode: Hashable, Sendable {
        /// The symbol's USR (Unified Symbol Reference).
        let usr: String
        /// The symbol name.
        let name: String
        /// The kind of symbol.
        let kind: IndexedSymbolKind
        /// File where the symbol is defined (nil for external symbols).
        let definitionFile: String?
        /// Line number of definition.
        let definitionLine: Int?
        /// Whether this is an external (cross-module) symbol — a sink, never a
        /// candidate for an unused finding.
        let isExternal: Bool

        init(
            usr: String,
            name: String,
            kind: IndexedSymbolKind,
            definitionFile: String? = nil,
            definitionLine: Int? = nil,
            isExternal: Bool = false
        ) {
            self.usr = usr
            self.name = name
            self.kind = kind
            self.definitionFile = definitionFile
            self.definitionLine = definitionLine
            self.isExternal = isExternal
        }

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.usr == rhs.usr }
        func hash(into hasher: inout Hasher) { hasher.combine(usr) }
    }

    // MARK: - IndexDependencyKind

    /// Kinds of dependencies detected from the index.
    enum IndexDependencyKind: String, Sendable {
        case call
        case typeReference
        case inheritance
        case protocolWitness
        case read
        case write
        case override
        /// A member → its enclosing type: a reachable member (a called init, a
        /// used method) keeps the type alive. The reverse edge is intentionally
        /// absent so a reachable type does NOT resurrect its dead members.
        case containedBy
    }

    // MARK: - IndexDependencyEdge

    /// An edge representing a dependency between symbols.
    struct IndexDependencyEdge: Hashable, Sendable {
        let fromUSR: String
        let toUSR: String
        let kind: IndexDependencyKind

        init(fromUSR: String, toUSR: String, kind: IndexDependencyKind) {
            self.fromUSR = fromUSR
            self.toUSR = toUSR
            self.kind = kind
        }
    }

    // MARK: - IndexGraphConfiguration

    /// Configuration for the index-based dependency graph.
    struct IndexGraphConfiguration: Sendable {
        /// Include cross-module edges (references into other modules).
        var includeCrossModuleEdges: Bool

        init(includeCrossModuleEdges: Bool = true) {
            self.includeCrossModuleEdges = includeCrossModuleEdges
        }

        static let `default` = Self()
    }

    // MARK: - IndexBasedDependencyGraph

    /// Dependency graph built from IndexStoreDB data. Provides accurate,
    /// USR-precise cross-module dependency tracking by leveraging the
    /// compiler's pre-built index store — the reachability oracle that
    /// replaces deadwood's name-level syntax edges under `--index-store`.
    ///
    /// Built and queried on one synchronous stretch inside
    /// `IndexReachabilityBridge`; never shared across tasks, so no locking.
    final class IndexBasedDependencyGraph {
        /// Configuration.
        let configuration: IndexGraphConfiguration

        /// All nodes in the graph, keyed by USR.
        private var nodes: [String: IndexSymbolNode] = [:]

        /// Adjacency list (outgoing edges from each node), keyed by USR.
        private var edges: [String: Set<IndexDependencyEdge>] = [:]

        /// Files included in the analysis scope (standardized).
        private let analysisFiles: Set<String>

        /// Maps an accessor's own USR (a getter or setter) to the USR of the
        /// property or subscript it belongs to. Swift's index gives every
        /// accessor its own symbol, distinct from the property, so a use
        /// recorded from inside the accessor's body — the common case, since
        /// that is where a computed property's code lives — would otherwise
        /// attach to a node nothing ever roots or reaches. Canonicalizing
        /// through this map folds the accessor back into its property.
        private var accessorAliases: [String: String] = [:]

        init(analysisFiles: [String], configuration: IndexGraphConfiguration = .default) {
            self.analysisFiles = Set(
                analysisFiles.map { Self.canonicalPath($0) })
            self.configuration = configuration
        }

        /// Canonical path used for both node files and lookups so a temp-dir
        /// symlink (`/var` → `/private/var`) never splits the same file.
        static func canonicalPath(_ path: String) -> String {
            URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        }

        // MARK: - Building

        /// Build the dependency graph from an index reader.
        func build(from reader: IndexStoreReader) {
            nodes.removeAll()
            edges.removeAll()
            accessorAliases.removeAll()
            collectDefinitions(from: reader)
            buildEdges(from: reader)
        }

        /// Definition nodes located inside the analysis scope.
        var definitionNodes: [IndexSymbolNode] {
            nodes.values.filter { !$0.isExternal && $0.definitionFile != nil }
        }

        /// For each USR of `dead`, the USRs of `dead` it has an edge to —
        /// the same shape as the syntax graph's dead-code grouping, so one
        /// declaration only dead code uses can be reported grouped under
        /// the declaration that heads its chain.
        /// - Complexity: O(D + E_D) for the dead USRs and their edges.
        func deadSuccessors(of dead: Set<String>) -> [String: [String]] {
            var successors: [String: [String]] = [:]
            for usr in dead {
                let targets = (edges[usr] ?? []).map(\.toUSR).filter { dead.contains($0) }
                if !targets.isEmpty {
                    successors[usr] = targets
                }
            }
            return successors
        }

        // MARK: - Reachability

        /// USRs reachable from `roots` over the index edges, computed on
        /// deadwood's shared `DenseGraph` (integer BFS, bit-packed visited).
        func reachableUSRs(fromRootUSRs roots: Set<String>) -> Set<String> {
            let usrList = Array(nodes.keys)
            guard !usrList.isEmpty else { return [] }

            var indexByUSR: [String: Int32] = [:]
            indexByUSR.reserveCapacity(usrList.count)
            for (index, usr) in usrList.enumerated() {
                indexByUSR[usr] = Int32(index)
            }

            var flatEdges: [(from: Int32, to: Int32)] = []
            flatEdges.reserveCapacity(edges.values.reduce(0) { $0 + $1.count })
            for (from, outgoing) in edges {
                guard let fromIndex = indexByUSR[from] else { continue }
                for edge in outgoing {
                    guard let toIndex = indexByUSR[edge.toUSR] else { continue }
                    flatEdges.append((fromIndex, toIndex))
                }
            }

            var rootIndices: Set<Int32> = []
            for usr in roots {
                if let index = indexByUSR[usr] {
                    rootIndices.insert(index)
                }
            }

            let dense = DenseGraph(nodeCount: usrList.count, edges: flatEdges, roots: rootIndices)
            let reachableIndices = dense.computeReachableSequential()

            var reachable = Set<String>()
            reachable.reserveCapacity(reachableIndices.count)
            for index in reachableIndices {
                reachable.insert(usrList[index])
            }
            return reachable
        }

        // MARK: - Definition + edge collection

        /// Collect all symbol definitions from files in scope: the
        /// member→enclosing-type containment edges and the protocol/override
        /// witness edges those definitions carry, and the accessor→property
        /// aliases that let a computed property's own body count as its use.
        private func collectDefinitions(from reader: IndexStoreReader) {
            for filePath in analysisFiles {
                for occurrence in reader.rawOccurrences(inFile: filePath) {
                    guard isDefinitionLike(occurrence.roles) else { continue }

                    // A getter or setter is defined as its own symbol, related
                    // to its property/subscript by `.accessorOf`. Alias it and
                    // stop: the property's own definition occurrence supplies
                    // the node, so nothing here should shadow it.
                    if let owner = occurrence.relations.first(where: { $0.roles.contains(.accessorOf) }) {
                        accessorAliases[occurrence.symbol.usr] = owner.symbol.usr
                        continue
                    }

                    let usr = occurrence.symbol.usr

                    for relation in occurrence.relations {
                        // A member's definition carries a `.childOf` relation
                        // to its enclosing type. The edge member→type means a
                        // reachable member (e.g. a called `init`) keeps the
                        // type alive — the common case where `Foo()`
                        // references the initializer, not the type name.
                        // (Inheritance is handled conservatively in the
                        // bridge via deadwood's parsed conformance lists,
                        // which are more reliable than the index's
                        // structural relations.)
                        if relation.roles.contains(.childOf) {
                            addEdge(from: usr, to: canonical(relation.symbol.usr), kind: .containedBy)
                        }
                        // An override or protocol witness carries an
                        // `.overrideOf` relation straight to the base member
                        // or protocol requirement it satisfies, by USR — no
                        // by-name matching needed. Using the base through
                        // dynamic dispatch must be able to reach every
                        // conformer, so the edge runs base → override.
                        if relation.roles.contains(.overrideOf) {
                            addEdge(from: canonical(relation.symbol.usr), to: usr, kind: .override)
                        }
                    }

                    guard nodes[usr] == nil else { continue }
                    nodes[usr] = IndexSymbolNode(
                        usr: usr,
                        name: occurrence.symbol.name,
                        kind: IndexedSymbolKind(from: occurrence.symbol.kind),
                        definitionFile: Self.canonicalPath(occurrence.location.path),
                        definitionLine: occurrence.location.line,
                        isExternal: false
                    )
                }
            }
        }

        /// The USR a declaration keeps in the graph: a property or
        /// subscript's own USR, or the property/subscript an accessor's USR
        /// belongs to.
        private func canonical(_ usr: String) -> String {
            accessorAliases[usr] ?? usr
        }

        /// Build edges from all references in scope.
        private func buildEdges(from reader: IndexStoreReader) {
            for filePath in analysisFiles {
                for occurrence in reader.rawOccurrences(inFile: filePath) {
                    processOccurrence(occurrence)
                }
            }
        }

        /// Extract edges from one occurrence via its containment relations.
        private func processOccurrence(_ occurrence: SymbolOccurrence) {
            let roles = occurrence.roles
            let targetUSR = canonical(occurrence.symbol.usr)
            guard indicatesUsage(roles) else { return }

            for relation in occurrence.relations {
                let relatedUSR = canonical(relation.symbol.usr)
                let relatedRoles = relation.roles

                // The containing symbol references the target.
                if relatedRoles.contains(.containedBy) {
                    let kind: IndexDependencyKind =
                        if roles.contains(.call) { .call } else if roles.contains(.read) {
                            .read
                        } else if roles.contains(.write) { .write } else { .typeReference }
                    addEdge(from: relatedUSR, to: targetUSR, kind: kind)
                }
                // The target is a base of (extended by) the related symbol.
                if relatedRoles.contains(.baseOf) {
                    addEdge(from: targetUSR, to: relatedUSR, kind: .inheritance)
                }
                // The target overrides the related symbol.
                if relatedRoles.contains(.overrideOf) {
                    addEdge(from: targetUSR, to: relatedUSR, kind: .override)
                }
            }

            ensureNodeExists(usr: targetUSR, symbol: occurrence.symbol, isExternal: true)
        }

        private func ensureNodeExists(usr: String, symbol: Symbol, isExternal: Bool) {
            guard nodes[usr] == nil else { return }
            nodes[usr] = IndexSymbolNode(
                usr: usr,
                name: symbol.name,
                kind: IndexedSymbolKind(from: symbol.kind),
                isExternal: isExternal
            )
        }

        private func addEdge(from: String, to: String, kind: IndexDependencyKind) {
            edges[from, default: []].insert(
                IndexDependencyEdge(fromUSR: from, toUSR: to, kind: kind))
        }
    }

    // MARK: - Role helpers

    private func isDefinitionLike(_ roles: SymbolRole) -> Bool {
        roles.contains(.definition) || roles.contains(.declaration)
    }

    private func indicatesUsage(_ roles: SymbolRole) -> Bool {
        roles.contains(.reference) || roles.contains(.call) || roles.contains(.read)
            || roles.contains(.write)
    }
#endif
