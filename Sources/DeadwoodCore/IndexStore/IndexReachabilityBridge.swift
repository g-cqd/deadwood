//  New in deadwood: the seam that makes `--index-store` a drop-in reachability
//  oracle. deadwood's syntax reachability resolves a reference to *every*
//  same-named declaration (name-level over-approximation); the index resolves
//  it to the one USR the compiler recorded. This bridge keeps deadwood's rich
//  root detection and the entire downstream finding pipeline unchanged, and
//  swaps ONLY the edge set: it seeds a BFS over the index's USR-precise edges
//  from the same roots the syntax graph uses, then maps the reachable USRs
//  back onto declaration indices. Everything after (confidence, kind gates,
//  member collapse, suppression) is identical to syntax mode, so the finding
//  *set* differs exactly where — and only where — the index is more precise.

import SymbolFacts

#if canImport(IndexStoreDB)
    import Foundation
    import ProjectModel

    struct IndexReachabilityBridge {
        /// Reachable declaration-index sets computed over the index edges,
        /// plus a one-line summary for stderr.
        struct Result: Sendable {
            /// Declaration indices reachable with test roots (the primary
            /// oracle output — the analogue of the syntax graph's reachable
            /// set).
            let reachableWithTests: Set<Int>
            /// Declaration indices reachable from production-only roots
            /// (production mode); nil otherwise.
            let reachableInProduction: Set<Int>?
            /// How many corpus declarations resolved to an index USR. Zero
            /// means the discovered index does not cover the analyzed files
            /// (a wrong/stale store): the caller must fall back to syntax
            /// rather than silently mark everything reachable.
            let resolvedCount: Int
            /// One-line index summary (symbol counts, resolution rate).
            let summary: String
            /// Declarations unreachable from any root, grouped exactly as
            /// the syntax graph groups them (``DependencyExtractor/deadGroupResults``):
            /// a declaration nothing names heads its group, and a
            /// declaration only dead code uses is reported apart, naming
            /// its dead users, at the weakest confidence along the chain.
            let deadGroupResults: [UnusedCode]
        }

        /// Compute index-backed reachability over the store `reader` holds open.
        func computeReachability(
            result: AnalysisResult,
            context: CorpusContext,
            configuration: UnusedCodeConfiguration,
            rootConfiguration: RootDetectionConfiguration,
            productionMode: Bool,
            testScoped: [Bool],
            reader: IndexStoreReader,
            analysisFiles: [String],
            uncoveredFiles: [String] = [],
            verbose: Bool = false
        ) async -> Result {
            reader.pollForChanges()

            let graph = IndexBasedDependencyGraph(analysisFiles: analysisFiles)
            await graph.build(from: reader)

            let declarations = result.declarations.declarations
            let declToUSR = Self.mapDeclarationsToUSRs(
                declarations: declarations,
                definitionNodes: graph.definitionNodes
            )
            // What a name stands for from inside a declaration, as Swift looks it up: used for what the index does not say.
            let resolver = NameResolver(
                declarations: declarations,
                context: context,
                declToUSR: declToUSR,
                graph: graph
            )
            // The uses in a body that the source has and the index does not: a build that skips function bodies leaves
            // them out, as it does for anything an observer or a macro generates. They count only once the body is reached.
            let incomplete = Self.usesMissingFromIndex(
                mapping: declToUSR,
                result: result,
                context: context,
                graph: graph
            )

            // Declarations the index oracle must never flag, mirroring the
            // syntax graph's conservatism: locals (ambiguous line-mapping; the
            // dead-store pass owns them) and in-corpus protocol requirements /
            // witnesses (kept alive by the protocol, but invoked through
            // dispatch that leaves no by-name index reference).
            let forcedReachable = Self.forcedReachableIndices(
                declarations: declarations,
                context: context
            )
            // Forced declarations also SEED the BFS: their USRs join the root
            // set so the symbols they reference (an error case a witness throws,
            // a helper a default impl calls) propagate reachability and aren't
            // themselves left dangling as false positives.
            let forcedUSRs = Set(forcedReachable.compactMap { declToUSR[$0] })

            // D2: a file the index does not cover draws no edge, so what only it uses would look dead. Its references,
            // from deadwood's own parse, keep every definition of the name they use alive: conservative, by name.
            // D3: code the compiler attributes to no declaration of the corpus (a `#Preview` body, top-level statements) draws
            // no edge either, and the nodes deadwood roots for it have no USR. What it names is rooted by name, as D2 does.
            let uncoveredRoots = Self.namedByUncoveredFiles(
                uncoveredFiles,
                result: result,
                context: context,
                graph: graph
            ).merged(
                with: Self.namedByRootCode(
                    result: result,
                    context: context,
                    configuration: rootConfiguration,
                    graph: graph
                )
            ).merged(
                with: Self.namedByUnmappedDeclarations(
                    declToUSR: declToUSR,
                    result: result,
                    context: context,
                    configuration: rootConfiguration,
                    resolver: resolver
                )
            )

            // With-test roots — deadwood's own rich root detection, projected
            // onto the USRs those roots resolve to, plus the forced seeds.
            let reachableWithTests = Self.reachableIndices(
                declarations: declarations,
                declToUSR: declToUSR,
                reachableUSRs: Self.reachableUSRs(
                    in: graph,
                    from: Self.rootUSRs(
                        declarations: declarations,
                        declToUSR: declToUSR,
                        context: context,
                        configuration: rootConfiguration,
                        excludingTestScoped: nil,
                        externalWitnesses: graph.externalWitnessUSRs
                    ),
                    alsoRooted: forcedUSRs.union(uncoveredRoots.all),
                    incomplete: incomplete,
                    resolver: resolver
                ),
                forcedReachable: forcedReachable
            )

            var reachableInProduction: Set<Int>?
            if productionMode {
                var productionConfig = rootConfiguration
                productionConfig.treatTestsAsRoot = false
                reachableInProduction = Self.reachableIndices(
                    declarations: declarations,
                    declToUSR: declToUSR,
                    reachableUSRs: Self.reachableUSRs(
                        in: graph,
                        from: Self.rootUSRs(
                            declarations: declarations,
                            declToUSR: declToUSR,
                            context: context,
                            configuration: productionConfig,
                            excludingTestScoped: testScoped,
                            externalWitnesses: graph.externalWitnessUSRs
                        ),
                        alsoRooted: forcedUSRs.union(uncoveredRoots.production),
                        incomplete: incomplete,
                        resolver: resolver
                    ),
                    forcedReachable: forcedReachable
                )
            }

            // The zero-reference count is a pass of its own over every file's occurrences (D5): it feeds the summary
            // only, so only a verbose run pays for it.
            var summary = "index: \(graph.definitionNodes.count) symbols in scope"
            if verbose {
                let zeroReference = IndexStoreAnalyzer(reader: reader, files: analysisFiles).findUnusedSymbols().count
                summary += ", \(zeroReference) with zero index references"
            }
            summary += "; \(declToUSR.count)/\(declarations.count) declarations resolved to USRs"
            if !incomplete.isEmpty {
                summary +=
                    "; \(incomplete.count) with uses the index lacks, found by name where reached (a store written by a build that "
                    + "skipped function bodies is partial)"
            }

            // Dead-code grouping shares its confidence and kind-gating logic
            // with the syntax graph; only the successor lookup differs,
            // resolved here (in USR space) and mapped back to declaration
            // indices, since the graph and the USR map live only in this
            // function.
            let detector = ReachabilityBasedDetector(
                configuration: configuration,
                extractionConfiguration: DependencyExtractionConfiguration(
                    rootDetection: rootConfiguration,
                    treatProtocolRequirementsAsRoot: true
                )
            )
            let own = detector.deadCandidates(
                declarations: declarations,
                reachable: reachableWithTests,
                context: context
            )
            let deadGroupResults = detector.deadGroupResults(
                declarations: declarations,
                own: own,
                successors: Self.declarationSuccessors(
                    of: own.keys,
                    declToUSR: declToUSR,
                    graph: graph
                ),
                context: context
            )

            return Result(
                reachableWithTests: reachableWithTests,
                reachableInProduction: reachableInProduction,
                resolvedCount: declToUSR.count,
                summary: summary,
                deadGroupResults: deadGroupResults
            )
        }

        /// Definitions rooted by name: every definition of a base name a root's code uses. `production` leaves out the roots
        /// that are test code, as production roots leave out test roots.
        struct NameRoots {
            var all: Set<String> = []
            var production: Set<String> = []

            func merged(with other: NameRoots) -> NameRoots {
                NameRoots(all: all.union(other.all), production: production.union(other.production))
            }
        }

        /// The definitions a name stands for. `helper` names `helper()` and `helper(_:)`. A type's name also stands for its
        /// initializers, as `Type(...)` calls one; `init` itself names none, or every initializer of the corpus would be
        /// named by any `.init(...)`.
        private struct DefinitionNames {
            private var byName: [Substring: [String]] = [:]
            private let initializers: [String: [String]]

            init(_ graph: IndexBasedDependencyGraph) {
                initializers = graph.initializersByEnclosing
                for node in graph.definitionNodes {
                    let base = indexBaseName(node.name)
                    if base == "init" { continue }
                    byName[Substring(base), default: []].append(node.usr)
                }
            }

            /// The USRs `identifier` stands for.
            func usrs(named identifier: String) -> [String] {
                (byName[Substring(identifier)] ?? []).flatMap { [$0] + (initializers[$0] ?? []) }
            }
        }

        /// The definitions named by references in `files`, by base name; `production` leaves out the references of test
        /// files.
        private static func namedByUncoveredFiles(
            _ files: [String],
            result: AnalysisResult,
            context: CorpusContext,
            graph: IndexBasedDependencyGraph
        ) -> NameRoots {
            guard !files.isEmpty else { return NameRoots() }
            let names = DefinitionNames(graph)
            var roots = NameRoots()
            for file in files {
                let isTest = context.isTestFile(file)
                for reference in result.references.find(inFile: file) {
                    for usr in names.usrs(named: reference.identifier) {
                        roots.all.insert(usr)
                        if !isTest { roots.production.insert(usr) }
                    }
                }
            }
            return roots
        }

        /// A use the source has in a body and the index does not record for the declaration.
        struct MissingUse: Sendable {
            let identifier: String
            /// A bare identifier (`spacing`), which Swift looks up from the declaration outward, as opposed to a member of
            /// something (`view.spacing`, `.spacing`), which only its base type can say.
            let isBare: Bool
        }

        /// For each mapped declaration with a body, the names of the corpus that its source uses and the index did not record;
        /// and for each construction `Type(...)` whose initializer it did not record, the type.
        ///
        /// The index is the authority on what it records. What it cannot have is the uses of a build that skipped function
        /// bodies (Xcode's "prepare for indexing" does), and uses that it attributes elsewhere than to the declaration's lines
        /// (a wrapped property's observer is recorded in its setter). So it asks the index what the declaration refers to, by
        /// name, wherever the occurrences are, with its accessors and local functions. Not counted: a name that the declaration
        /// binds itself, whether the syntax declares it (a parameter) or only its text shows it (`if let x`, a closure's
        /// parameters, a `case let`), since the index records no use of a local; the label of a memberwise call, which the
        /// syntax collects as a write; and anything of a declaration without a body of its own.
        private static func usesMissingFromIndex(
            mapping: [Int: String],
            result: AnalysisResult,
            context: CorpusContext,
            graph: IndexBasedDependencyGraph
        ) -> [Int: [MissingUse]] {
            let declarations = result.declarations.declarations
            var declaredNames = Set<String>()
            var typeNames = Set<String>()
            var candidatesByFile: [String: [Int32]] = [:]
            for (index, declaration) in declarations.enumerated() {
                if declaration.kind != .parameter, !context.isLocalDeclaration(declaration) {
                    declaredNames.insert(declaration.name)
                    if [.class, .struct, .enum, .actor].contains(declaration.kind) {
                        typeNames.insert(declaration.name)
                    }
                }
                candidatesByFile[declaration.location.file, default: []].append(Int32(index))
            }
            let bodyKinds: Set<DeclarationKind> = [
                .function, .method, .initializer, .deinitializer, .subscript, .variable, .constant,
            ]
            var missing: [Int: [MissingUse]] = [:]
            for (file, candidates) in candidatesByFile {
                // The source of the file, read once, to see which names a declaration binds itself.
                let lines =
                    (try? String(contentsOfFile: file, encoding: .utf8))
                    .map { $0.split(separator: "\n", omittingEmptySubsequences: false) } ?? []
                let references = result.references.find(inFile: file).sorted { $0.location.line < $1.location.line }
                guard !references.isEmpty else { continue }
                var owned = DependencyExtractor.referenceOwners(
                    refs: references,
                    candidates: candidates,
                    declarations: declarations,
                    context: context
                )
                let bound = candidates.map { declarations[Int($0)] }
                    .filter { $0.kind == .parameter || context.isLocalDeclaration($0) }
                // Reachability gives the references of an initializer to its type, which holds everything outside a member's
                // own body. The index records them against the initializer, so that is where they are checked.
                let initializers = candidates.filter {
                    let declaration = declarations[Int($0)]
                    return (declaration.kind == .initializer || declaration.kind == .deinitializer)
                        && !context.isLocalDeclaration(declaration)
                }
                if !initializers.isEmpty {
                    for (owner, referenceIndices) in owned where !bodyKinds.contains(declarations[Int(owner)].kind) {
                        var stays: [Int] = []
                        for referenceIndex in referenceIndices {
                            let line = references[referenceIndex].location.line
                            if let initializer = initializers.first(where: {
                                declarations[Int($0)].range.start.line <= line
                                    && line <= declarations[Int($0)].range.end.line
                            }) {
                                owned[initializer, default: []].append(referenceIndex)
                            } else {
                                stays.append(referenceIndex)
                            }
                        }
                        owned[owner] = stays
                    }
                }
                for (owner, referenceIndices) in owned {
                    guard let usr = mapping[Int(owner)] else { continue }
                    let declaration = declarations[Int(owner)]
                    guard bodyKinds.contains(declaration.kind) else { continue }
                    // After the line of the declaration, whose own line holds the signature. A declaration written on one line
                    // has its body there too.
                    let first =
                        declaration.range.start.line == declaration.range.end.line
                        ? declaration.location.line : declaration.location.line + 1
                    let boundHere = Set(
                        bound.filter {
                            $0.location.line >= declaration.range.start.line
                                && $0.location.line <= declaration.range.end.line
                        }.map(\.name)
                    )
                    let named = referenceIndices.map { references[$0] }.filter {
                        // A local shadows a bare name, not a member (`self.provider` is not the parameter `provider`).
                        $0.context != .write && $0.location.line >= first && declaredNames.contains($0.identifier)
                            && ($0.context == .memberAccessMember || !boundHere.contains($0.identifier))
                    }
                    guard !named.isEmpty else { continue }
                    let recorded = graph.usedNames(by: usr)
                    func isConstruction(_ reference: Reference) -> Bool {
                        reference.context == .call && typeNames.contains(reference.identifier)
                    }
                    // A name the index lacks is a use it lost, unless the body binds that name itself: a local such as
                    // `guard let device = …` beside a member `device` is never recorded by the index, and the syntax does not
                    // always declare it. The text of the declaration says what it binds.
                    let bodyText: String =
                        lines.isEmpty
                        ? ""
                        : lines[max(0, declaration.location.line - 1)..<min(lines.count, declaration.range.end.line)]
                            .joined(separator: "\n")
                    let boundInText = LocalBindings.names(in: bodyText)
                    let members = named.filter {
                        !isConstruction($0)
                            && ($0.context == .memberAccessMember || $0.isQualified
                                || !boundInText.contains($0.identifier))
                    }
                    let lost = members.filter { !recorded.contains($0.identifier) }
                    // `Type(...)` calls an initializer of the type, which the index records as `init:Type`. The type's name
                    // alone is also recorded for a mention that calls nothing, so it cannot stand for the call. What it
                    // asks for is the type and its initializers, which a construction keeps alive anyway.
                    let constructions = named.filter {
                        isConstruction($0) && !recorded.contains("init:" + $0.identifier)
                    }
                    var seen = Set<String>()
                    let uses = (lost + constructions).compactMap {
                        reference -> MissingUse? in
                        let isBare = reference.context != .memberAccessMember && !reference.isQualified
                        guard seen.insert("\(isBare):\(reference.identifier)").inserted else { return nil }
                        return MissingUse(identifier: reference.identifier, isBare: isBare)
                    }
                    if !uses.isEmpty { missing[Int(owner)] = uses }
                }
            }
            return missing
        }

        /// What a name stands for from inside a declaration.
        ///
        /// A bare identifier is looked up as Swift does: the members of the enclosing type (with its extensions), then those
        /// it inherits, including the extensions of the protocols and classes it conforms to or derives from, then the same for
        /// each type around it, then what is declared at the top level. The first of these levels with a declaration of the
        /// name is the answer. A member of something else (`view.spacing`) can be on any type, so every definition of the
        /// name stands for it.
        struct NameResolver: Sendable {
            let declToUSR: [Int: String]
            private let declarations: [Declaration]
            private let context: CorpusContext
            private let names: DefinitionNames
            private let initializers: [String: [String]]
            private var membersByTypeAndName: [String: [String: [Int]]] = [:]
            private var topLevelByName: [String: [Int]] = [:]
            /// The modules each file imports.
            private var importsByFile: [String: Set<String>] = [:]

            init(
                declarations: [Declaration],
                context: CorpusContext,
                declToUSR: [Int: String],
                graph: IndexBasedDependencyGraph
            ) {
                self.declarations = declarations
                self.context = context
                self.declToUSR = declToUSR
                names = DefinitionNames(graph)
                initializers = graph.initializersByEnclosing
                for (index, declaration) in declarations.enumerated() {
                    if declaration.kind == .import {
                        importsByFile[declaration.location.file, default: []].insert(declaration.name)
                    }
                    switch declaration.kind {
                    case .extension, .import, .parameter, .topLevelCode: continue
                    default: break
                    }
                    if context.isLocalDeclaration(declaration) { continue }
                    if let enclosing = context.nearestEnclosingType(of: declaration) {
                        membersByTypeAndName[Self.typeKey(enclosing.name), default: [:]][declaration.name, default: []]
                            .append(index)
                    } else {
                        topLevelByName[declaration.name, default: []].append(index)
                    }
                }
            }

            /// `Inner` for `Outer.Inner`: how code names the type.
            private static func typeKey(_ name: String) -> String {
                String(name.split(separator: ".").last ?? Substring(name))
            }

            /// The USRs the use stands for when written inside the declaration at `owner`.
            func usrs(of use: MissingUse, from owner: Int) -> [String] {
                guard use.isBare else { return names.usrs(named: use.identifier) }
                var result: [String] = []
                for index in candidates(for: use.identifier, from: declarations[owner], at: owner) {
                    guard let usr = declToUSR[index] else { continue }
                    result.append(usr)
                    result.append(contentsOf: initializers[usr] ?? [])
                }
                return result
            }

            private func candidates(for identifier: String, from owner: Declaration, at ownerIndex: Int) -> [Int] {
                // What the owner's module can see: its own declarations and those of the modules its file imports. The USR
                // starts with the module (`s:18Oculavis_Share_IOS…`), so a declaration of another module that the file does
                // not import is not what the name means, even if it has the same name.
                let ownModule = declToUSR[ownerIndex].flatMap(Self.module(ofUSR:))
                let imported = importsByFile[owner.location.file] ?? []
                func visible(_ indices: [Int]) -> [Int] {
                    guard let ownModule else { return indices }
                    return indices.filter { index in
                        guard let module = declToUSR[index].flatMap(Self.module(ofUSR:)) else { return true }
                        return module == ownModule || imported.contains(module)
                    }
                }
                for level in context.enclosingTypeDeclarations(of: owner) {
                    let type = Self.typeKey(level.name)
                    let own = visible(membersByTypeAndName[type]?[identifier] ?? [])
                    if !own.isEmpty { return own }
                    var inherited: [Int] = []
                    for base in context.allConformances(ofTypeNamed: level.name) {
                        inherited.append(contentsOf: membersByTypeAndName[Self.typeKey(base)]?[identifier] ?? [])
                    }
                    inherited = visible(inherited)
                    if !inherited.isEmpty { return inherited }
                }
                return visible(topLevelByName[identifier] ?? [])
            }

            /// `Oculavis_Share_IOS` for `s:18Oculavis_Share_IOS6loggerSo…`; nil for a USR of another shape (an extension's).
            static func module(ofUSR usr: String) -> String? {
                guard usr.hasPrefix("s:") else { return nil }
                var rest = usr.dropFirst(2)
                let digits = rest.prefix { $0.isNumber }
                guard let length = Int(digits), length > 0 else { return nil }
                rest = rest.dropFirst(digits.count)
                guard rest.count >= length else { return nil }
                return String(rest.prefix(length))
            }
        }

        /// The definitions named by the code of root declarations that map to no index symbol: the references each owns. A root
        /// counts as used, but the walk starts from symbols, so without this what it uses (a `body` that maps to nothing roots
        /// nothing) would look dead. A bare identifier stands for what Swift's lookup finds from that
        /// declaration; the member of something else, for every definition of the name. Declarations that do map are not
        /// touched, so the precision stays where the index has it.
        private static func namedByUnmappedDeclarations(
            declToUSR: [Int: String],
            result: AnalysisResult,
            context: CorpusContext,
            configuration: RootDetectionConfiguration,
            resolver: NameResolver
        ) -> NameRoots {
            let declarations = result.declarations.declarations
            let detector = RootDetector(configuration: configuration)
            var unmappedByFile: [String: Set<Int32>] = [:]
            var candidatesByFile: [String: [Int32]] = [:]
            for (index, declaration) in declarations.enumerated() {
                candidatesByFile[declaration.location.file, default: []].append(Int32(index))
                // Only a root: an unmapped declaration is not seeded, so nothing it uses would be reached. Any other has its
                // real symbol in the graph, which is reached, with what it uses, if something uses it.
                if declToUSR[index] == nil, !context.isLocalDeclaration(declaration),
                    detector.rootReason(for: declaration, context: context) != nil
                {
                    unmappedByFile[declaration.location.file, default: []].insert(Int32(index))
                }
            }
            guard !unmappedByFile.isEmpty else {
                return NameRoots()
            }
            var roots = NameRoots()
            for (file, unmapped) in unmappedByFile {
                let references = result.references.find(inFile: file).sorted { $0.location.line < $1.location.line }
                let owned = DependencyExtractor.referenceOwners(
                    refs: references,
                    candidates: candidatesByFile[file] ?? [],
                    declarations: declarations,
                    context: context
                )
                let isTest = context.isTestFile(file)
                // A name bound inside the declaration (a parameter, a local) is not the member of the same name, and the label
                // of a memberwise call, which the syntax collects as a write, names no symbol: neither is a use.
                let bound = (candidatesByFile[file] ?? []).map { declarations[Int($0)] }
                    .filter { $0.kind == .parameter || context.isLocalDeclaration($0) }
                for owner in unmapped {
                    let declaration = declarations[Int(owner)]
                    let boundHere = Set(
                        bound.filter {
                            $0.location.line >= declaration.range.start.line
                                && $0.location.line <= declaration.range.end.line
                        }.map(\.name)
                    )
                    for referenceIndex in owned[owner] ?? [] {
                        let reference = references[referenceIndex]
                        guard reference.context != .write else { continue }
                        let isBare = reference.context != .memberAccessMember && !reference.isQualified
                        if isBare, boundHere.contains(reference.identifier) { continue }
                        let use = MissingUse(identifier: reference.identifier, isBare: isBare)
                        for usr in resolver.usrs(of: use, from: Int(owner)) {
                            roots.all.insert(usr)
                            if !isTest { roots.production.insert(usr) }
                        }
                    }
                }
            }
            return roots
        }

        /// The definitions named by the code of the root nodes deadwood synthesizes for code that belongs to no declaration
        /// (`#Preview` bodies, top-level statements): the references inside each node's line range.
        private static func namedByRootCode(
            result: AnalysisResult,
            context: CorpusContext,
            configuration: RootDetectionConfiguration,
            graph: IndexBasedDependencyGraph
        ) -> NameRoots {
            let detector = RootDetector(configuration: configuration)
            let nodes = result.declarations.declarations.filter {
                $0.kind == .topLevelCode && detector.rootReason(for: $0, context: context) != nil
            }
            guard !nodes.isEmpty else { return NameRoots() }
            let names = DefinitionNames(graph)
            var roots = NameRoots()
            for node in nodes {
                let file = node.location.file
                let isTest = context.isTestFile(file)
                for reference in result.references.find(inFile: file)
                where reference.location.line >= node.range.start.line && reference.location.line <= node.range.end.line
                {
                    for usr in names.usrs(named: reference.identifier) {
                        roots.all.insert(usr)
                        if !isTest { roots.production.insert(usr) }
                    }
                }
            }
            return roots
        }

        /// The index graph's edges among `indices`, translated from USR
        /// space to declaration indices via `declToUSR`. Every key of
        /// `indices` has a USR (the caller draws them from a USR-mapped
        /// set), so only the targets need the reverse lookup.
        private static func declarationSuccessors(
            of indices: some Sequence<Int>,
            declToUSR: [Int: String],
            graph: IndexBasedDependencyGraph
        ) -> [Int: [Int]] {
            var usrToIndex: [String: Int] = [:]
            usrToIndex.reserveCapacity(declToUSR.count)
            for (index, usr) in declToUSR {
                usrToIndex[usr] = index
            }
            let usrs = Set(indices.compactMap { declToUSR[$0] })
            var successors: [Int: [Int]] = [:]
            for (fromUSR, toUSRs) in graph.deadSuccessors(of: usrs) {
                guard let fromIndex = usrToIndex[fromUSR] else { continue }
                let targets = toUSRs.compactMap { usrToIndex[$0] }
                if !targets.isEmpty {
                    successors[fromIndex] = targets
                }
            }
            return successors
        }

        // MARK: - Mapping

        /// Map each declaration index to the index USR of its definition,
        /// matching by (canonical file, name) and the nearest recorded line.
        /// The nearest-line rule distinguishes same-named symbols in different
        /// scopes (the precise case the syntax graph conflates) while
        /// absorbing the small line offset an attribute/modifier prefix can
        /// introduce between deadwood's declaration line and the index's
        /// symbol line. Unmatched declarations are left unmapped and treated
        /// conservatively as reachable (the index cannot judge them).
        static func mapDeclarationsToUSRs(
            declarations: [Declaration],
            definitionNodes: [IndexSymbolNode]
        ) -> [Int: String] {
            var byNameFile: [String: [(line: Int, usr: String, kind: IndexedSymbolKind)]] = [:]
            for node in definitionNodes {
                guard let file = node.definitionFile, let line = node.definitionLine else { continue }
                let key = nameKey(file: file, name: baseName(node.name))
                for definedAt in [line] + node.alternateDefinitionLines {
                    byNameFile[key, default: []].append((definedAt, node.usr, node.kind))
                }
            }

            // How many declarations of the corpus share a name in a file. One declaration of its name there, matched by
            // one symbol of that name, is that symbol wherever the index puts it (see below).
            var declarationsByNameFile: [String: Int] = [:]
            for declaration in declarations {
                let file = IndexBasedDependencyGraph.canonicalPath(declaration.location.file)
                declarationsByNameFile[nameKey(file: file, name: unquoted(declaration.name)), default: 0] += 1
            }

            // A type conforming via a macro (`@Observable`, `@Model`, ...) gets
            // a compiler-synthesized `extension Type: Protocol {}` indexed
            // under the type's own name, often at the type's own line — a
            // same-name, same-line rival for the type's own declaration. A
            // nominal type never means that extension.
            let nominalTypeKinds: Set<DeclarationKind> = [.class, .struct, .enum, .protocol, .actor]

            var declToUSR: [Int: String] = [:]
            declToUSR.reserveCapacity(declarations.count)
            for (index, declaration) in declarations.enumerated() {
                let file = IndexBasedDependencyGraph.canonicalPath(declaration.location.file)
                let key = nameKey(file: file, name: unquoted(declaration.name))
                guard var candidates = byNameFile[key], !candidates.isEmpty else { continue }
                if nominalTypeKinds.contains(declaration.kind) {
                    let ownDeclarations = candidates.filter { $0.kind != .extension }
                    if !ownDeclarations.isEmpty { candidates = ownDeclarations }
                }
                let declLine = declaration.location.line
                guard
                    let best = candidates.min(by: {
                        abs($0.line - declLine) < abs($1.line - declLine)
                    })
                else { continue }
                if abs(best.line - declLine) <= lineMatchTolerance {
                    declToUSR[index] = best.usr
                } else if declarationsByNameFile[key] == 1, Set(candidates.map(\.usr)).count == 1 {
                    // The line is off by more than the tolerance: the index describes the file as an earlier build saw it.
                    // Nothing else in the file has the name, though, so this is the declaration, and leaving it unmapped
                    // would leave it, and what it uses, out of the walk.
                    declToUSR[index] = best.usr
                }
            }
            return declToUSR
        }

        /// USRs of the declarations deadwood considers roots. `excludingTestScoped`
        /// (production mode) drops roots that live in test code.
        /// The root USRs; `insideTheirType` are those rooted only so the member itself is not reported.
        private struct RootUSRs {
            var all: Set<String> = []
            var insideTheirType: Set<String> = []
        }

        /// What the roots reach. A root that something else roots outright (a forced declaration, a name an uncovered file
        /// uses) is outside use after all, so only the rest stay inside their type.
        ///
        /// A reached declaration whose body the index describes only in part (`incomplete`) also reaches what its source
        /// names and the index lacks, found the way Swift looks the name up from there. Those are added as roots and the walk
        /// is repeated, since what they reach can have such a body too. A declaration nothing reaches adds nothing, so dead
        /// code stays dead.
        private static func reachableUSRs(
            in graph: IndexBasedDependencyGraph,
            from roots: RootUSRs,
            alsoRooted: Set<String>,
            incomplete: [Int: [MissingUse]],
            resolver: NameResolver
        ) -> Set<String> {
            var extra = Set<String>()
            var applied = Set<Int>()
            while true {
                let reached = graph.reachableUSRs(
                    fromRootUSRs: roots.all.union(alsoRooted).union(extra),
                    rootsInsideTheirType: roots.insideTheirType.subtracting(alsoRooted).subtracting(extra)
                )
                var grew = false
                for (index, uses) in incomplete where !applied.contains(index) {
                    guard let usr = resolver.declToUSR[index], reached.contains(usr) else { continue }
                    applied.insert(index)
                    for use in uses {
                        for target in resolver.usrs(of: use, from: index) where extra.insert(target).inserted {
                            grew = true
                        }
                    }
                }
                if !grew { return reached }
            }
        }

        private static func rootUSRs(
            declarations: [Declaration],
            declToUSR: [Int: String],
            context: CorpusContext,
            configuration: RootDetectionConfiguration,
            excludingTestScoped testScoped: [Bool]?,
            externalWitnesses: Set<String>
        ) -> RootUSRs {
            let detector = RootDetector(configuration: configuration)
            var roots = RootUSRs()
            // What the compiler says overrides or witnesses a symbol outside the scope is called from there, whatever the
            // name or the protocol: an unknown protocol, one the type inherits through another, a default implementation.
            // Like a property wrapper's property, it is rooted so that it is not reported, not to keep its type alive.
            // In production mode the ones that are test code are left out, as the other roots are.
            var testScopedUSRs: Set<String> = []
            if let testScoped {
                for (index, usr) in declToUSR where testScoped[index] { testScopedUSRs.insert(usr) }
            }
            for usr in externalWitnesses where !testScopedUSRs.contains(usr) {
                roots.all.insert(usr)
                roots.insideTheirType.insert(usr)
            }
            for (index, declaration) in declarations.enumerated() {
                if let testScoped, testScoped[index] { continue }
                guard let reason = detector.rootReason(for: declaration, context: context),
                    let usr = declToUSR[index]
                else { continue }
                roots.all.insert(usr)
                if reason == .swiftUIPropertyWrapper || reason == .propertyWrapperContract {
                    roots.insideTheirType.insert(usr)
                }
            }
            return roots
        }

        /// Declaration indices reachable per the index. Unmapped declarations
        /// and `forcedReachable` declarations are conservatively reachable so
        /// neither an index coverage gap nor a dispatch-only witness can
        /// manufacture a false "unused" verdict.
        private static func reachableIndices(
            declarations: [Declaration],
            declToUSR: [Int: String],
            reachableUSRs: Set<String>,
            forcedReachable: Set<Int>
        ) -> Set<Int> {
            var reachable = forcedReachable
            reachable.reserveCapacity(declarations.count)
            for index in declarations.indices {
                guard let usr = declToUSR[index] else {
                    reachable.insert(index)
                    continue
                }
                if reachableUSRs.contains(usr) {
                    reachable.insert(index)
                }
            }
            return reachable
        }

        /// Declarations the index oracle must never flag: locals, in-corpus
        /// protocol requirements, and same-named witnesses of in-corpus
        /// protocols.
        static func forcedReachableIndices(
            declarations: [Declaration],
            context: CorpusContext
        ) -> Set<Int> {
            // Requirement names per in-corpus protocol.
            var requirementNames: [String: Set<String>] = [:]
            // In-corpus type names, and the subset of them named as a base /
            // conformance of some type (a superclass or protocol kept alive by
            // its subtypes — the index's structural inheritance relations are
            // unreliable, so deadwood's parsed conformance lists drive this).
            var typeNames = Set<String>()
            var baseNames = Set<String>()
            let typeKinds: Set<DeclarationKind> = [
                .class, .struct, .enum, .protocol, .actor, .typealias,
            ]
            for declaration in declarations {
                if typeKinds.contains(declaration.kind) {
                    typeNames.insert(declaration.name)
                }
                for conformance in declaration.conformances {
                    baseNames.insert(CorpusContext.baseName(ofConformance: conformance))
                }
                guard let enclosing = context.nearestEnclosingType(of: declaration),
                    enclosing.kind == .protocol
                else { continue }
                requirementNames[enclosing.name, default: []].insert(declaration.name)
            }
            let inCorpusBaseTypes = baseNames.intersection(typeNames)

            var forced = Set<Int>()
            for (index, declaration) in declarations.enumerated() {
                if context.isLocalDeclaration(declaration) {
                    forced.insert(index)
                    continue
                }
                if context.isProtocolRequirement(declaration) {
                    forced.insert(index)
                    continue
                }
                // A type that is a base/protocol of an in-corpus type is kept
                // alive by its subtypes/conformers.
                if typeKinds.contains(declaration.kind), inCorpusBaseTypes.contains(declaration.name) {
                    forced.insert(index)
                    continue
                }
                guard let enclosing = context.nearestEnclosingType(of: declaration),
                    enclosing.kind != .protocol
                else { continue }

                // Default implementation: a member declared in an extension of
                // an in-corpus protocol (`extension P { ... }`) is a witness the
                // protocol keeps alive.
                if context.protocolNames.contains(enclosing.name) {
                    forced.insert(index)
                    continue
                }

                // Witness: a member whose enclosing type conforms to an
                // in-corpus protocol that declares a requirement of this name.
                let inCorpusConformances = context.allConformances(ofTypeNamed: enclosing.name)
                    .intersection(context.protocolNames)
                for proto in inCorpusConformances
                where requirementNames[proto]?.contains(declaration.name) == true {
                    forced.insert(index)
                    break
                }
            }
            return forced
        }

        private static let lineMatchTolerance = 5

        /// IndexStoreDB reports function/method/init names with their argument
        /// clause (`shared()`, `fetch(id:)`); deadwood declaration names are
        /// base names (`shared`, `fetch`). Strip from the first `(` so the two
        /// match. Line disambiguation still separates same-base overloads.
        private static func baseName(_ name: String) -> String {
            indexBaseName(name)
        }

        /// A raw identifier keeps its surrounding backticks in
        /// `Declaration.name` (`` `a role is granted` ``), a spelling Swift
        /// Testing favors for sentence-style test names; the index records
        /// the identifier itself, without them. Strip a matched pair before
        /// building the lookup key, or every backtick-quoted declaration —
        /// the test method most of all — fails to map, taking its whole
        /// reachable subtree down with it.
        private static func unquoted(_ name: String) -> String {
            guard name.count >= 2, name.hasPrefix("`"), name.hasSuffix("`") else { return name }
            return String(name.dropFirst().dropLast())
        }

        private static func nameKey(file: String, name: String) -> String {
            "\(file)\u{0}\(name)"
        }
    }

    // MARK: - IndexProjectLocator

    /// Locates the SwiftPM/Xcode project root for a set of analyzed files, so
    /// the fallback manager can discover `.build/.../index/store`.
    enum IndexProjectLocator {
        static func projectRoot(for files: [String], fallback cwd: String) -> String {
            ProjectLayout.discover(paths: files)?.root ?? cwd
        }
    }
#endif
