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
    import IndexStoreSupport

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
        /// The other lines the same file defines it at, in other units of the store. A store keeps the units of every build
        /// that wrote to it (another configuration, an earlier commit), and the ones of an earlier build describe the file as
        /// it was: the symbol is at its current line in one of them.
        let alternateDefinitionLines: [Int]
        /// Whether this is an external (cross-module) symbol — a sink, never a
        /// candidate for an unused finding.
        let isExternal: Bool

        init(
            usr: String,
            name: String,
            kind: IndexedSymbolKind,
            definitionFile: String? = nil,
            definitionLine: Int? = nil,
            alternateDefinitionLines: [Int] = [],
            isExternal: Bool = false
        ) {
            self.usr = usr
            self.name = name
            self.kind = kind
            self.definitionFile = definitionFile
            self.definitionLine = definitionLine
            self.alternateDefinitionLines = alternateDefinitionLines
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

        /// The definitions that override or witness a symbol the analysis scope does not define, each with that symbol: a
        /// requirement of a protocol of the SDK or of another module, a method of a framework class. Code outside the
        /// scope calls them through the base, so nothing inside it need.
        private var overridesOfExternalSymbols: [(usr: String, base: String)] = []

        /// Definitions whose USR carries an error type (`Xe`: a type the unit that defined them could not resolve), by the USR
        /// of the type that contains them followed by their name. A call from another unit records the resolved USR of the
        /// same member, which shares that prefix and matches no definition of its own.
        private var unresolvedDefinitionsByPrefix: [String: [String]] = [:]
        private var unresolvedPrefixLengths: Set<Int> = []

        /// The same for initializers, which carry no name in their USR: by the USR of their type, and matched to a call whose
        /// USR starts with it and ends in `fc`, the mark of an initializer.
        private var unresolvedInitializersByType: [String: [String]] = [:]
        private var unresolvedInitializerTypeLengths: Set<Int> = []

        /// The definitions each definition contains, by USR (see ``usedNames(by:)``); built on first use.
        private var containedDefinitions: [String: [String]]?

        init(analysisFiles: [String], configuration: IndexGraphConfiguration = .default) {
            self.analysisFiles = Set(
                analysisFiles.map { Self.canonicalPath($0) }
            )
            self.configuration = configuration
        }

        /// Canonical path used for both node files and lookups so a temp-dir
        /// symlink (`/var` → `/private/var`) never splits the same file.
        static func canonicalPath(_ path: String) -> String {
            URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        }

        // MARK: - Building

        /// Build the dependency graph from an index reader: each file is queried once, in parallel, into a summary of
        /// its definitions and uses; the summaries are then merged in file order, aliases first, so an accessor defined
        /// in one file folds into its property wherever it is used.
        func build(from reader: IndexStoreReader) async {
            nodes.removeAll()
            edges.removeAll()
            accessorAliases.removeAll()
            overridesOfExternalSymbols.removeAll()
            containedDefinitions = nil
            unresolvedDefinitionsByPrefix.removeAll()
            unresolvedPrefixLengths.removeAll()
            unresolvedInitializersByType.removeAll()
            unresolvedInitializerTypeLengths.removeAll()
            let files = analysisFiles.sorted()
            let width = max(1, ProcessInfo.processInfo.activeProcessorCount)
            var summaries = [FileSummary?](repeating: nil, count: files.count)
            await withTaskGroup(of: (Int, FileSummary).self) { group in
                var next = 0
                func schedule() {
                    let index = next
                    let file = files[index]
                    group.addTask { (index, FileSummary(reader.occurrences(inFile: file))) }
                    next += 1
                }
                while next < min(width, files.count) { schedule() }
                for await (index, summary) in group {
                    summaries[index] = summary
                    if next < files.count { schedule() }
                }
            }
            for summary in summaries.compactMap(\.self) {
                for (accessor, owner) in summary.aliases { accessorAliases[accessor] = owner }
            }
            var canonicalPaths: [String: String] = [:]
            for summary in summaries.compactMap(\.self) {
                for definition in summary.definitions { add(definition, canonicalPaths: &canonicalPaths) }
            }
            indexUnresolvedDefinitions()
            // What a definition overrides or witnesses, as the definition or the conformance says. Every definition of the
            // scope is a node by now, so a base that is none is outside it.
            var overrides: [(usr: String, base: String)] = []
            for summary in summaries.compactMap(\.self) {
                for definition in summary.definitions {
                    for base in definition.overridden { overrides.append((definition.usr, base)) }
                }
                for link in summary.witnessLinks {
                    for base in link.bases { overrides.append((canonical(link.usr), base)) }
                }
            }
            for (usr, base) in overrides {
                let base = canonical(base)
                if nodes[base] == nil {
                    overridesOfExternalSymbols.append((usr, base))
                } else if nodes[usr] != nil {
                    addEdge(from: base, to: usr, kind: .override)
                }
            }
            for summary in summaries.compactMap(\.self) {
                for use in summary.uses { add(use) }
            }
        }

        /// The base names of the symbols the definition `usr` refers to, as the compiler recorded it: from the definition
        /// itself, its accessors (folded into it), and the local functions and closures-as-symbols inside it. `fetch(id:)`
        /// is `fetch`, `getter:count` is `count`, and a call of `Model`'s initializer is also `init:Model`.
        /// - Complexity: O(E) the first time (it indexes the containers), then O(depth · degree).
        func usedNames(by usr: String) -> Set<String> {
            if containedDefinitions == nil {
                var children: [String: [String]] = [:]
                for (from, edgesFrom) in edges {
                    for edge in edgesFrom where edge.kind == .containedBy {
                        children[edge.toUSR, default: []].append(from)
                    }
                }
                containedDefinitions = children
            }
            var names = Set<String>()
            var visited: Set<String> = [usr]
            var pending = [usr]
            while let current = pending.popLast() {
                for edge in edges[current] ?? [] where edge.kind != .containedBy {
                    guard let node = nodes[edge.toUSR] else { continue }
                    let name = Self.useName(node.name)
                    names.insert(name)
                    // An initializer is also recorded with its type: `init:Model` is a call of one of `Model`'s.
                    if name == "init" {
                        for container in edges[edge.toUSR] ?? [] where container.kind == .containedBy {
                            if let type = nodes[container.toUSR] { names.insert("init:" + Self.useName(type.name)) }
                        }
                    }
                }
                for child in containedDefinitions?[current] ?? [] where visited.insert(child).inserted {
                    // Members of a nested type are not uses by the declaration; local functions are.
                    if let kind = nodes[child]?.kind, kind == .function || kind == .method { pending.append(child) }
                }
            }
            return names
        }

        private static func useName(_ name: String) -> String {
            var name = Substring(name)
            for prefix in ["getter:", "setter:", "didSet:", "willSet:", "modify:", "_modify:", "read:"]
            where name.hasPrefix(prefix) {
                name = name.dropFirst(prefix.count)
                break
            }
            return indexBaseName(String(name))
        }

        /// The USRs of the definitions that override or witness a symbol defined outside the analysis scope.
        var externalWitnessUSRs: Set<String> {
            Set(overridesOfExternalSymbols.map(\.usr))
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

        /// The USRs of each type's initializers, by the type's USR: the definitions whose name is `init`, under their enclosing
        /// declaration.
        var initializersByEnclosing: [String: [String]] {
            var byType: [String: [String]] = [:]
            for node in definitionNodes where node.name == "init" || node.name.hasPrefix("init(") {
                for edge in edges[node.usr] ?? [] where edge.kind == .containedBy {
                    byType[edge.toUSR, default: []].append(node.usr)
                }
            }
            return byType
        }

        // MARK: - Reachability

        /// USRs reachable from `roots` over the index edges.
        ///
        /// A member keeps its enclosing types alive (a called `init`, a used method), but only when something outside the
        /// type reaches it: a type whose members merely refer to each other is as dead as the code that never creates it.
        /// So a `containedBy` edge is followed from a member to a type that does not already hold the code that reached
        /// the member. `rootsInsideTheirType` are roots that exist so the member itself is not reported (a `@Published`
        /// property the framework reads): they do not count as outside use.
        /// - Complexity: O((V + E) · depth), the depth being how deeply types nest.
        func reachableUSRs(
            fromRootUSRs roots: Set<String>,
            rootsInsideTheirType: Set<String> = []
        ) -> Set<String> {
            let usrList = Array(nodes.keys)
            guard !usrList.isEmpty else { return [] }

            var indexByUSR: [String: Int] = [:]
            indexByUSR.reserveCapacity(usrList.count)
            for (index, usr) in usrList.enumerated() {
                indexByUSR[usr] = index
            }

            var outgoing = [[Int]](repeating: [], count: usrList.count)
            var enclosing = [Int](repeating: -1, count: usrList.count)
            for (from, edgesFrom) in edges {
                guard let fromIndex = indexByUSR[from] else { continue }
                for edge in edgesFrom {
                    guard let toIndex = indexByUSR[edge.toUSR] else { continue }
                    if edge.kind == .containedBy {
                        enclosing[fromIndex] = toIndex
                    } else {
                        outgoing[fromIndex].append(toIndex)
                    }
                }
            }

            var visited = [Bool](repeating: false, count: usrList.count)
            var queue: [Int] = []
            func reach(_ node: Int) {
                guard !visited[node] else { return }
                visited[node] = true
                queue.append(node)
            }
            /// Whether `node` is `type` or lies within it.
            func isInside(_ node: Int, _ type: Int) -> Bool {
                var current = node
                while true {
                    if current == type { return true }
                    guard enclosing[current] >= 0 else { return false }
                    current = enclosing[current]
                }
            }
            /// `user` (nil: the framework, outside everything) reached `member`: reach the types around it that do not hold
            /// `user`. Above the first one that does, `user` is inside as well.
            func keepEnclosingTypesAlive(of member: Int, reachedFrom user: Int?) {
                var current = member
                while enclosing[current] >= 0 {
                    let type = enclosing[current]
                    if let user, isInside(user, type) { return }
                    reach(type)
                    current = type
                }
            }

            for usr in roots {
                guard let node = indexByUSR[usr] else { continue }
                reach(node)
                if !rootsInsideTheirType.contains(usr) { keepEnclosingTypesAlive(of: node, reachedFrom: nil) }
            }
            var head = 0
            while head < queue.count {
                let user = queue[head]
                head += 1
                for target in outgoing[user] {
                    reach(target)
                    keepEnclosingTypesAlive(of: target, reachedFrom: user)
                }
            }

            var reachable = Set<String>()
            reachable.reserveCapacity(queue.count)
            for node in queue {
                reachable.insert(usrList[node])
            }
            return reachable
        }

        // MARK: - Definition + edge collection

        /// What one file's occurrences contribute, with no reference to the graph, so files are summarised in parallel.
        struct FileSummary: Sendable {
            struct Definition: Sendable {
                let usr: String
                let name: String
                let kind: IndexedSymbolKind
                let path: String
                let line: Int
                /// The enclosing types (`childOf`) and the bases this definition overrides or witnesses (`overrideOf`).
                let parents: [String]
                let overridden: [String]
            }

            struct Use: Sendable {
                let target: String
                let name: String
                let kind: IndexedSymbolKind
                /// The symbols containing the use, with the kind of edge; the bases it extends; what it overrides.
                let containers: [(usr: String, kind: IndexDependencyKind)]
                let bases: [String]
                let overrides: [String]
            }

            var aliases: [(accessor: String, owner: String)] = []
            var definitions: [Definition] = []
            var uses: [Use] = []
            /// A conformance written apart from the type (an extension, often in another file) records what a member
            /// witnesses at the conformance, as an implicit occurrence of the member, not on the member's definition.
            var witnessLinks: [(usr: String, bases: [String])] = []

            /// Each occurrence's file is in the corpus's spelling (analyzerkit `IndexQueries`); the rest is IndexStoreDB's
            /// record, relations included.
            init(_ occurrences: [IndexQueries.Occurrence]) {
                for found in occurrences {
                    let occurrence = found.record
                    let roles = occurrence.roles
                    if isDefinitionLike(roles) {
                        // A getter or setter is its own symbol, related to its property or subscript by `.accessorOf`:
                        // alias it and stop, since the property's own definition supplies the node.
                        if let owner = occurrence.relations.first(where: { $0.roles.contains(.accessorOf) }) {
                            aliases.append((occurrence.symbol.usr, owner.symbol.usr))
                        } else {
                            definitions.append(
                                Definition(
                                    usr: occurrence.symbol.usr,
                                    name: occurrence.symbol.name,
                                    kind: IndexedSymbolKind(from: occurrence.symbol.kind),
                                    path: found.file,
                                    line: occurrence.location.line,
                                    parents: occurrence.relatedUSRs(with: .childOf),
                                    overridden: occurrence.relatedUSRs(with: .overrideOf)
                                )
                            )
                        }
                    }
                    if !isDefinitionLike(roles) {
                        let bases = occurrence.relatedUSRs(with: .overrideOf)
                        if !bases.isEmpty { witnessLinks.append((occurrence.symbol.usr, bases)) }
                    }
                    guard indicatesUsage(roles) else { continue }
                    let kind: IndexDependencyKind =
                        if roles.contains(.call) { .call } else if roles.contains(.read) {
                            .read
                        } else if roles.contains(.write) { .write } else { .typeReference }
                    uses.append(
                        Use(
                            target: occurrence.symbol.usr,
                            name: occurrence.symbol.name,
                            kind: IndexedSymbolKind(from: occurrence.symbol.kind),
                            containers: occurrence.relations.filter { $0.roles.contains(.containedBy) }
                                .map { ($0.symbol.usr, kind) },
                            bases: occurrence.relatedUSRs(with: .baseOf),
                            overrides: occurrence.relatedUSRs(with: .overrideOf)
                        )
                    )
                }
            }
        }

        /// A definition in scope: its node, the member→enclosing-type edge (a reachable member, such as a called
        /// `init`, keeps its type alive), and the base→override edge (using a base through dynamic dispatch reaches
        /// every conformer). Inheritance is handled in the bridge from deadwood's parsed conformance lists.
        private func add(_ definition: FileSummary.Definition, canonicalPaths: inout [String: String]) {
            let usr = definition.usr
            // A parameter or a local only describes its function: it does not keep the function alive, as a member keeps its
            // type. With the edge, the forced locals that seed the walk reached every function that has one.
            if definition.kind != .parameter, definition.kind != .variable {
                for parent in definition.parents { addEdge(from: usr, to: canonical(parent), kind: .containedBy) }
            }
            for base in definition.overridden { addEdge(from: canonical(base), to: usr, kind: .override) }
            let path: String
            if let known = canonicalPaths[definition.path] {
                path = known
            } else {
                path = Self.canonicalPath(definition.path)
                canonicalPaths[definition.path] = path
            }
            if let known = nodes[usr] {
                // Another unit of the store defines it again. Keeping only the first line would map the declaration to the
                // line an earlier build had, and a declaration that maps to nothing cannot be reached.
                if known.definitionFile == path, let line = known.definitionLine, line != definition.line,
                    !known.alternateDefinitionLines.contains(definition.line)
                {
                    nodes[usr] = IndexSymbolNode(
                        usr: usr,
                        name: known.name,
                        kind: known.kind,
                        definitionFile: path,
                        definitionLine: line,
                        alternateDefinitionLines: known.alternateDefinitionLines + [definition.line],
                        isExternal: false
                    )
                }
                return
            }
            nodes[usr] = IndexSymbolNode(
                usr: usr,
                name: definition.name,
                kind: definition.kind,
                definitionFile: path,
                definitionLine: definition.line,
                isExternal: false
            )
        }

        /// A use: the containing symbol references the target; the target is a base of, or overrides, the related one.
        private func add(_ use: FileSummary.Use) {
            let target = canonical(use.target)
            for container in use.containers {
                addEdge(from: canonical(container.usr), to: target, kind: container.kind)
                for definition in unresolvedDefinitions(matching: target) {
                    addEdge(from: canonical(container.usr), to: definition, kind: container.kind)
                }
            }
            for base in use.bases { addEdge(from: target, to: canonical(base), kind: .inheritance) }
            for overridden in use.overrides { addEdge(from: target, to: canonical(overridden), kind: .override) }
            if nodes[target] == nil {
                nodes[target] = IndexSymbolNode(usr: target, name: use.name, kind: use.kind, isExternal: true)
            }
        }

        /// Records the definitions with an unresolved type under the prefix a resolved USR of the same member would share:
        /// everything up to and including the length-prefixed name (`…SSOLoginC16startAppAuthFlow`), which holds the module,
        /// the containing types and the name, wherever the member is declared.
        private func indexUnresolvedDefinitions() {
            for node in nodes.values where !node.isExternal && node.usr.contains("Xe") {
                guard node.kind != .parameter, node.kind != .variable else { continue }
                let name = Self.useName(node.name)
                if name == "init" {
                    if let parent = (edges[node.usr] ?? []).first(where: { $0.kind == .containedBy })?.toUSR {
                        unresolvedInitializersByType[parent, default: []].append(node.usr)
                        unresolvedInitializerTypeLengths.insert(parent.utf8.count)
                    }
                    continue
                }
                guard !name.isEmpty, let prefix = Self.memberPrefix(of: node.usr, named: name) else { continue }
                unresolvedDefinitionsByPrefix[prefix, default: []].append(node.usr)
                unresolvedPrefixLengths.insert(prefix.utf8.count)
            }
        }

        /// The USR up to and including the length-prefixed name of a member, which a resolved USR of the same member shares
        /// (`s:3App5LoginC5start` for `s:3App5LoginC5startyXeXeF` and `s:3App5LoginC5start8provider5emailySS_tF`); nil when
        /// the name is not in it.
        static func memberPrefix(of usr: String, named name: String) -> String? {
            guard let marker = usr.range(of: String(name.utf8.count) + name, options: .backwards) else { return nil }
            return String(usr[..<marker.upperBound])
        }

        /// The unresolved definitions a use of `target` stands for, when `target` is no definition of the scope.
        private func unresolvedDefinitions(matching target: String) -> [String] {
            guard !(unresolvedPrefixLengths.isEmpty && unresolvedInitializerTypeLengths.isEmpty),
                nodes[target].map(\.isExternal) ?? true
            else { return [] }
            var matches: [String] = []
            if target.hasSuffix("fc") {
                matches.append(
                    contentsOf: Self.definitions(
                        sharing: target,
                        prefixOfLengths: unresolvedInitializerTypeLengths,
                        in: unresolvedInitializersByType
                    )
                )
            }
            matches.append(
                contentsOf: Self.definitions(
                    sharing: target,
                    prefixOfLengths: unresolvedPrefixLengths,
                    in: unresolvedDefinitionsByPrefix
                )
            )
            return matches
        }

        /// The definitions in `table` whose key is a prefix of `target` of one of `lengths` bytes.
        private static func definitions(
            sharing target: String,
            prefixOfLengths lengths: Set<Int>,
            in table: [String: [String]]
        ) -> [String] {
            var found: [String] = []
            for length in lengths where target.utf8.count > length {
                let key = String(decoding: target.utf8.prefix(length), as: UTF8.self)
                if let definitions = table[key] { found.append(contentsOf: definitions) }
            }
            return found
        }

        /// The USR a declaration keeps in the graph: a property or subscript's own USR, or the property/subscript an
        /// accessor's USR belongs to.
        private func canonical(_ usr: String) -> String {
            accessorAliases[usr] ?? usr
        }

        private func addEdge(from: String, to: String, kind: IndexDependencyKind) {
            edges[from, default: []].insert(IndexDependencyEdge(fromUSR: from, toUSR: to, kind: kind))
        }
    }

    // MARK: - Names

    /// `fetch` for `fetch(id:)`, `init` for `init()`. Only the trailing group of argument labels goes: a raw identifier may hold
    /// parentheses itself (`` `handle(a) works` ``, which the index names `handle(a) works()`).
    func indexBaseName(_ name: String) -> String {
        guard name.hasSuffix(")"), let open = name.lastIndex(of: "(") else { return name }
        let labels = name[name.index(after: open)..<name.index(before: name.endIndex)]
        guard labels.allSatisfy({ $0 == ":" || $0 == "_" || $0.isLetter || $0.isNumber }) else { return name }
        return String(name[..<open])
    }

    // MARK: - Role helpers

    extension SymbolOccurrence {
        /// The USRs of the symbols related to this occurrence by `role`.
        fileprivate func relatedUSRs(with role: SymbolRole) -> [String] {
            relations.filter { $0.roles.contains(role) }.map(\.symbol.usr)
        }
    }

    private func isDefinitionLike(_ roles: SymbolRole) -> Bool {
        roles.contains(.definition) || roles.contains(.declaration)
    }

    private func indicatesUsage(_ roles: SymbolRole) -> Bool {
        roles.contains(.reference) || roles.contains(.call) || roles.contains(.read)
            || roles.contains(.write)
    }
#endif
