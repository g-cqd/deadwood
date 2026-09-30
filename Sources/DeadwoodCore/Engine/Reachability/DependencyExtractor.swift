//  Lifted from SwiftStaticAnalysis (MIT) — UnusedCodeDetector/Reachability/DependencyExtractor.swift.
//  Changes during the lift:
//  - protocol requirement/witness association rewritten on `CorpusContext`.
//    SSA matched members with `scope.id.contains(typeName)`, but scope IDs
//    are `file:counter`, so the match fired only when the file happened to
//    be named after the type. Requirements now resolve through the scope
//    tree, and witnesses must live in a type whose merged conformance list
//    names the protocol (or in an extension of the protocol itself).
//  - wholesale type→method edges dropped: they made every member of a live
//    type live, which defeats member-level unused detection.
//  - AsyncStream edge streaming (`streamEdges`) dropped along with
//    `ParallelMode.maximum`'s duplication pipeline.
//  - the dead-branch pass moved to `DeadBranchPass` (it consumes parsed
//    trees instead of re-reading files).

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

// MARK: - DependencyExtractor

/// Extracts dependencies from analysis results to build a reachability
/// graph.
///
/// Edge computation is parallel (pure per-declaration work joined by a
/// single batch insert into the graph actor); BFS itself is delegated to
/// the graph.
///
/// A reference points at every declaration sharing its name, so each
/// declaration's targets are deduplicated as they are collected. Emitting one
/// edge per reference and same-named declaration and deduplicating in the
/// graph afterwards held all of those edges for the whole corpus at once.
struct DependencyExtractor: Sendable {
    /// Configuration for extraction.
    let configuration: DependencyExtractionConfiguration

    init(configuration: DependencyExtractionConfiguration = .default) {
        self.configuration = configuration
    }

    /// Build a reachability graph from analysis results.
    func buildGraph(from result: AnalysisResult, context: CorpusContext) async -> ReachabilityGraph {
        await buildGraph(from: result, context: context, recordingRegionLevels: false).graph
    }

    /// Build the reachability graph and, when asked, the same edges with
    /// the region level of the code that draws each one: an edge is at
    /// the lowest level of the references drawing it (``RegionLevel``).
    func buildGraph(
        from result: AnalysisResult,
        context: CorpusContext,
        recordingRegionLevels: Bool
    ) async -> (graph: ReachabilityGraph, leveled: LeveledEdges?) {
        let graph = ReachabilityGraph()

        await graph.detectRoots(
            declarations: result.declarations.declarations,
            context: context,
            configuration: configuration.rootDetection
        )

        let leveled = await buildEdges(
            graph: graph, result: result, context: context, recordingRegionLevels: recordingRegionLevels)

        return (graph, leveled)
    }

    // MARK: - Edge building

    /// Compute each declaration's reference targets in parallel and
    /// batch-insert them; with `recordingRegionLevels`, also return them
    /// with their levels.
    private func buildEdges(
        graph: ReachabilityGraph,
        result: AnalysisResult,
        context: CorpusContext,
        recordingRegionLevels: Bool
    ) async -> LeveledEdges? {
        let allDeclarations = result.declarations.declarations

        // Name → declaration indices lookup (immutable copy for Sendable
        // capture). Indices are positions in the aggregated corpus array —
        // the graph's node identity.
        var declByNameMutable: [String: [Int32]] = [:]
        for (index, declaration) in allDeclarations.enumerated() {
            declByNameMutable[declaration.name, default: []].append(Int32(index))
        }
        let declByName = declByNameMutable

        // Per-file references sorted by line, built once: each declaration
        // binary-searches its line range instead of filtering the whole
        // file's reference list — O((D+R) log R) per file, not O(D·R).
        // With levels, each file holding regions also gets the level of
        // every sorted reference, aligned by index.
        var sortedRefsMutable: [String: [Reference]] = [:]
        var refLevelsMutable: [String: [UInt8]] = [:]
        sortedRefsMutable.reserveCapacity(result.references.byFile.count)
        for (file, refs) in result.references.byFile {
            let sorted = refs.sorted { $0.location.line < $1.location.line }
            sortedRefsMutable[file] = sorted
            if recordingRegionLevels, context.hasCodeRegions(inFile: file) {
                refLevelsMutable[file] = sorted.map {
                    UInt8(context.regionLevel(ofLine: $0.location.line, inFile: file).rawValue)
                }
            }
        }
        let sortedRefsByFile = sortedRefsMutable
        let refLevelsByFile = refLevelsMutable

        let maxConcurrency = ProcessInfo.processInfo.activeProcessorCount

        let targetsBySource = await ParallelProcessor.compactMap(
            Array(allDeclarations.enumerated()),
            maxConcurrency: maxConcurrency
        ) { entry -> (source: Int32, targets: [Int32], levels: [UInt8])? in
            let leveled = self.referenceTargets(
                of: entry.element,
                sortedRefsByFile: sortedRefsByFile,
                refLevelsByFile: recordingRegionLevels ? refLevelsByFile : nil,
                declByName: declByName,
                context: context
            )
            return leveled.targets.isEmpty ? nil : (Int32(entry.offset), leveled.targets, leveled.levels)
        }

        await graph.addTargets(targetsBySource.map { ($0.source, $0.targets) })

        var witnessEdges: [DependencyEdge] = []
        if configuration.trackProtocolWitnesses {
            witnessEdges = computeProtocolEdges(
                result: result,
                context: context,
                declByName: declByName
            )
            await graph.addEdges(witnessEdges)
        }

        guard recordingRegionLevels else { return nil }
        var edges = LeveledEdges(nodeCount: allDeclarations.count)
        for entry in targetsBySource {
            edges.add(source: entry.source, targets: entry.targets, levels: entry.levels)
        }
        for edge in witnessEdges {
            edges.add(source: edge.from, targets: [edge.to], levels: [0])
        }
        return edges
    }

    /// The declarations one declaration may depend on, each once, ascending
    /// (pure function): every declaration named like a reference inside the
    /// declaration's line range, or like that reference's qualifier
    /// (name-level over-approximation), and the types its annotation names.
    /// - Complexity: O(*r* + *t* log *t*) for *r* matches among the
    ///   references and *t* distinct targets.
    private func referenceTargets(
        of declaration: Declaration,
        sortedRefsByFile: [String: [Reference]],
        refLevelsByFile: [String: [UInt8]]?,
        declByName: [String: [Int32]],
        context: CorpusContext
    ) -> (targets: [Int32], levels: [UInt8]) {
        // Target → the lowest level of the references drawing it.
        var targets: [Int32: UInt8] = [:]
        func add(_ matches: [Int32], level: UInt8) {
            for match in matches {
                if let existing = targets[match], existing <= level { continue }
                targets[match] = level
            }
        }

        let file = declaration.location.file
        let fileRefs = sortedRefsByFile[file] ?? []
        let fileLevels = refLevelsByFile?[file]
        for index in referenceIndicesInScope(declaration: declaration, fileRefs: fileRefs) {
            let reference = fileRefs[index]
            let level = fileLevels?[index] ?? 0
            if let matches = declByName[reference.identifier] {
                add(matches, level: level)
            }
            if let qualifier = reference.qualifier, let matches = declByName[qualifier] {
                add(matches, level: level)
            }
        }

        // Type annotations reference their type names, from the
        // declaration's own line.
        if let typeAnnotation = declaration.typeAnnotation {
            let level =
                refLevelsByFile == nil
                ? 0 : UInt8(context.regionLevel(ofLine: declaration.location.line, inFile: file).rawValue)
            for typeName in extractTypeNames(from: typeAnnotation) {
                if let matches = declByName[typeName] {
                    add(matches, level: level)
                }
            }
        }

        let sorted = targets.keys.sorted()
        return (sorted, sorted.map { targets[$0] ?? 0 })
    }

    /// Indices of the references inside a declaration's line range: two
    /// binary searches over the file's line-sorted references bound the
    /// inclusive [start.line, end.line] subrange.
    private func referenceIndicesInScope(declaration: Declaration, fileRefs: [Reference]) -> Range<Int> {
        let startLine = declaration.range.start.line
        let endLine = declaration.range.end.line
        let lower = fileRefs.partitionPoint { $0.location.line >= startLine }
        let upper = fileRefs.partitionPoint { $0.location.line > endLine }
        return lower..<max(lower, upper)
    }

    /// Extract type names from a type annotation string.
    private func extractTypeNames(from typeAnnotation: String) -> [String] {
        var names: [String] = []

        let separators: [String] = ["[", "]", "<", ">", ",", ":", "(", ")", "->"]
        var cleaned =
            typeAnnotation
            .replacingAll("?", with: "")
            .replacingAll("!", with: "")
        for separator in separators {
            cleaned = cleaned.replacingAll(separator, with: " ")
        }

        for part in cleaned.split(separator: " ") {
            let name = String(part).trimmedHorizontalWhitespace
            if !name.isEmpty,
                name.first?.isUppercase == true,
                !isBuiltInType(name)
            {
                names.append(name)
            }
        }

        return names
    }

    private func isBuiltInType(_ name: String) -> Bool {
        let builtIns: Set<String> = [
            "Int", "Int8", "Int16", "Int32", "Int64",
            "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
            "Float", "Double", "Float16", "Float80",
            "Bool", "String", "Character",
            "Array", "Dictionary", "Set", "Optional",
            "Any", "AnyObject", "AnyClass",
            "Void", "Never",
            "Error", "Equatable", "Hashable", "Comparable",
            "Codable", "Encodable", "Decodable",
            "Sendable", "Identifiable",
        ]
        return builtIns.contains(name)
    }

    // MARK: - Protocol requirement / witness edges

    /// Two edge families keep protocol machinery alive precisely:
    ///
    /// 1. protocol → each of its requirements (a used protocol's interface
    ///    is used by definition), and
    /// 2. requirement → same-named members of conforming types (witnesses
    ///    are invoked through the requirement).
    private func computeProtocolEdges(
        result: AnalysisResult,
        context: CorpusContext,
        declByName: [String: [Int32]]
    ) -> [DependencyEdge] {
        var edges: [DependencyEdge] = []
        let allDeclarations = result.declarations.declarations

        // Protocol declarations and requirements grouped by protocol name,
        // both carrying their corpus indices.
        var protocolIndices: [Int32] = []
        var requirementsByProtocol: [String: [Int32]] = [:]
        for (index, declaration) in allDeclarations.enumerated() {
            if declaration.kind == .protocol {
                protocolIndices.append(Int32(index))
                continue
            }
            guard let enclosing = context.nearestEnclosingType(of: declaration),
                enclosing.kind == .protocol
            else { continue }
            requirementsByProtocol[enclosing.name, default: []].append(Int32(index))
        }
        guard !protocolIndices.isEmpty else { return edges }

        for protoIndex in protocolIndices {
            let proto = allDeclarations[Int(protoIndex)]
            let requirements = requirementsByProtocol[proto.name] ?? []

            if configuration.treatProtocolRequirementsAsRoot {
                for requirement in requirements {
                    edges.append(DependencyEdge(from: protoIndex, to: requirement))
                }
            }

            for requirement in requirements {
                let requirementName = allDeclarations[Int(requirement)].name
                for witness in declByName[requirementName] ?? [] {
                    guard
                        isWitness(
                            allDeclarations[Int(witness)], ofProtocol: proto.name, context: context)
                    else { continue }
                    edges.append(DependencyEdge(from: requirement, to: witness))
                }
            }
        }

        return edges
    }

    /// A declaration witnesses `protocolName` when its enclosing type's
    /// merged conformance list names the protocol, or when it lives in an
    /// extension of the protocol itself (default implementation).
    private func isWitness(
        _ declaration: Declaration,
        ofProtocol protocolName: String,
        context: CorpusContext
    ) -> Bool {
        guard let enclosing = context.nearestEnclosingType(of: declaration) else {
            return false
        }
        if enclosing.kind == .protocol {
            return false  // The requirement itself, not a witness.
        }
        if enclosing.name == protocolName {
            return true  // extension P { default implementation }
        }
        return context.conformances(ofTypeNamed: enclosing.name).contains(protocolName)
    }
}

// MARK: - DependencyExtractionConfiguration

/// Configuration for dependency extraction.
struct DependencyExtractionConfiguration: Sendable {
    /// Default configuration.
    static let `default` = Self()

    /// Root-detection settings forwarded to the graph.
    var rootDetection: RootDetectionConfiguration

    /// Add protocol → requirement edges.
    var treatProtocolRequirementsAsRoot: Bool

    /// Add requirement → witness edges.
    var trackProtocolWitnesses: Bool

    init(
        rootDetection: RootDetectionConfiguration = .default,
        treatProtocolRequirementsAsRoot: Bool = true,
        trackProtocolWitnesses: Bool = true
    ) {
        self.rootDetection = rootDetection
        self.treatProtocolRequirementsAsRoot = treatProtocolRequirementsAsRoot
        self.trackProtocolWitnesses = trackProtocolWitnesses
    }
}

// MARK: - ReachabilityBasedDetector

/// Unused code detector using reachability analysis.
struct ReachabilityBasedDetector: Sendable {
    /// Detection configuration.
    let configuration: UnusedCodeConfiguration

    /// Dependency extraction configuration.
    let extractionConfiguration: DependencyExtractionConfiguration

    init(
        configuration: UnusedCodeConfiguration = .default,
        extractionConfiguration: DependencyExtractionConfiguration = .default
    ) {
        self.configuration = configuration
        self.extractionConfiguration = extractionConfiguration
    }

    /// Detect unused code as the set of unreachable declarations. In
    /// production mode, reachability runs twice over the same graph — with
    /// test roots and without — and declarations only tests can reach come
    /// back as `.referencedOnlyByTests`.
    func detect(in result: AnalysisResult, context: CorpusContext) async -> [UnusedCode] {
        let extractor = DependencyExtractor(configuration: extractionConfiguration)
        let wantsRegions =
            (configuration.detectPreviewOnly || configuration.detectDebugOnly) && context.hasCodeRegions
        let (graph, leveledEdges) = await extractor.buildGraph(
            from: result, context: context, recordingRegionLevels: wantsRegions)

        // BFS backend: forced by `useParallelBFS`, else auto-selected
        // against the node-count threshold.
        let nodeCount = await graph.nodeCount
        let runParallel = configuration.useParallelBFS ?? (nodeCount >= configuration.parallelBFSThreshold)

        let reachableWithTests: Set<Int>
        if runParallel {
            reachableWithTests = await graph.computeReachableParallel()
        } else {
            reachableWithTests = await graph.computeReachable()
        }

        // Map indices back through the declaration array only here, at the
        // findings boundary — the graph never carries declarations.
        let declarations = result.declarations.declarations
        var results = neverReferencedResults(
            declarations: declarations,
            reachableWithTests: reachableWithTests,
            context: context
        )

        if configuration.productionMode {
            let classifier = TestScopeClassifier(testsGlob: configuration.testsGlob)
            let testScoped = classifier.classify(declarations: declarations, context: context)
            let reachableInProduction = await graph.computeReachable(
                fromRoots: productionRootIndices(
                    declarations: declarations, testScoped: testScoped, context: context))
            results.append(
                contentsOf: onlyTestedResults(
                    declarations: declarations,
                    reachableWithTests: reachableWithTests,
                    reachableInProduction: reachableInProduction,
                    testScoped: testScoped,
                    context: context
                ))
        }

        if let leveledEdges {
            results.append(
                contentsOf: regionOnlyResults(edges: leveledEdges, declarations: declarations, context: context))
        }

        return results
    }

    // MARK: - Region reachability

    /// Production code that only previews or `#if DEBUG` code reach: the
    /// lowest level at which a declaration becomes reachable is debug-only
    /// or preview (``LeveledReachability``). Code declared in a preview or
    /// `#if DEBUG` is never the subject: it already sits where it belongs.
    /// - Complexity: O(V + E).
    private func regionOnlyResults(
        edges: LeveledEdges,
        declarations: [Declaration],
        context: CorpusContext
    ) -> [UnusedCode] {
        let detector = RootDetector(configuration: extractionConfiguration.rootDetection)
        var roots: [(node: Int32, level: UInt8)] = []
        var declaredLevels = [RegionLevel](repeating: .production, count: declarations.count)
        for (index, declaration) in declarations.enumerated() {
            let level = context.regionLevel(ofLine: declaration.location.line, inFile: declaration.location.file)
            declaredLevels[index] = level
            if detector.rootReason(for: declaration, context: context) != nil {
                roots.append((Int32(index), UInt8(level.rawValue)))
            }
        }
        let reachedAt = LeveledReachability.levels(
            of: edges, roots: roots, levelCount: RegionLevel.allCases.count)

        var results: [UnusedCode] = []
        for (index, declaration) in declarations.enumerated() where declaredLevels[index] == .production {
            let onlyDebug: Bool
            switch reachedAt[index] {
            case UInt8(RegionLevel.debugOnly.rawValue): onlyDebug = true
            case UInt8(RegionLevel.preview.rawValue): onlyDebug = false
            default: continue
            }
            guard onlyDebug ? configuration.detectDebugOnly : configuration.detectPreviewOnly,
                let confidence = reportableConfidence(of: declaration, context: context)
            else { continue }
            results.append(
                UnusedCode(
                    declaration: declaration,
                    reason: onlyDebug ? .referencedOnlyByDebugCode : .referencedOnlyByPreviews,
                    confidence: confidence,
                    suggestion: onlyDebug
                        ? "Only #if DEBUG code reaches '\(declaration.name)' — move it under #if DEBUG"
                        : "Only previews reach '\(declaration.name)' — move it under #if DEBUG"
                ))
        }
        return results
    }

    // MARK: - Report tail (shared with the index-store oracle)

    /// Genuinely unreachable declarations (even with test roots): normal
    /// rules. Pure over a precomputed reachable-index set, so both the syntax
    /// graph and the `--index-store` bridge feed it their own reachability.
    func neverReferencedResults(
        declarations: [Declaration],
        reachableWithTests: Set<Int>,
        context: CorpusContext
    ) -> [UnusedCode] {
        var results: [UnusedCode] = []
        for index in 0..<declarations.count where !reachableWithTests.contains(index) {
            let declaration = declarations[index]
            guard let confidence = reportableConfidence(of: declaration, context: context) else {
                continue
            }
            results.append(
                UnusedCode(
                    declaration: declaration,
                    reason: .neverReferenced,
                    confidence: confidence,
                    suggestion:
                        "Unreachable from any entry point - consider removing '\(declaration.name)'"
                ))
        }
        return results
    }

    /// Production declarations that only the test pass reaches. Pure over
    /// precomputed reachable-index sets so the index bridge can reuse it with
    /// index-derived reachability.
    func onlyTestedResults(
        declarations: [Declaration],
        reachableWithTests: Set<Int>,
        reachableInProduction: Set<Int>,
        testScoped: [Bool],
        context: CorpusContext
    ) -> [UnusedCode] {
        var results: [UnusedCode] = []
        for (index, declaration) in declarations.enumerated() {
            guard reachableWithTests.contains(index),
                !reachableInProduction.contains(index),
                !testScoped[index]
            else { continue }
            guard let confidence = reportableConfidence(of: declaration, context: context) else {
                continue
            }
            results.append(
                UnusedCode(
                    declaration: declaration,
                    reason: .referencedOnlyByTests,
                    confidence: confidence,
                    suggestion:
                        "Only test code reaches '\(declaration.name)' — production code never uses it"
                ))
        }
        return results
    }

    /// Production roots: entry points that are not test-scoped, computed with
    /// test roots dropped. Shared by the syntax second pass and the index
    /// bridge's production pass.
    func productionRootIndices(
        declarations: [Declaration],
        testScoped: [Bool],
        context: CorpusContext
    ) -> Set<Int32> {
        var rootConfiguration = extractionConfiguration.rootDetection
        rootConfiguration.treatTestsAsRoot = false
        let detector = RootDetector(configuration: rootConfiguration)

        var productionRoots: Set<Int32> = []
        for (index, declaration) in declarations.enumerated()
        where !testScoped[index] && detector.rootReason(for: declaration, context: context) != nil {
            productionRoots.insert(Int32(index))
        }
        return productionRoots
    }

    /// Kind gate + confidence floor shared by both passes; nil when the
    /// declaration should not be reported.
    private func reportableConfidence(
        of declaration: Declaration,
        context: CorpusContext
    ) -> Confidence? {
        guard shouldReport(declaration) else { return nil }
        let confidence = declaration.unusedConfidence(context: context)
        guard confidence >= configuration.minimumConfidence else { return nil }
        return confidence
    }

    /// Kind-level report gate.
    private func shouldReport(_ declaration: Declaration) -> Bool {
        switch declaration.kind {
        case .constant, .variable:
            configuration.detectVariables
        case .function, .method:
            configuration.detectFunctions
        case .class, .enum, .protocol, .struct, .actor, .typealias:
            configuration.detectTypes
        case .enumCase:
            true
        case .import,
            .parameter, .initializer, .deinitializer, .subscript,
            .operator, .extension, .associatedtype, .topLevelCode:
            // Imports have their own pass; the rest have no rule —
            // name-level reference tracking cannot judge them reliably.
            false
        }
    }
}
