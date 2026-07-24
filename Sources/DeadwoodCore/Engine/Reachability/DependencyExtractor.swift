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

import Foundation

// MARK: - DependencyExtractor

/// Extracts dependencies from analysis results to build a reachability
/// graph.
///
/// Edge computation is parallel (pure per-declaration work joined by a
/// single batch insert into the graph actor); BFS itself is delegated to
/// the graph.
struct DependencyExtractor: Sendable {
    /// Configuration for extraction.
    let configuration: DependencyExtractionConfiguration

    init(configuration: DependencyExtractionConfiguration = .default) {
        self.configuration = configuration
    }

    /// Build a reachability graph from analysis results.
    func buildGraph(from result: AnalysisResult, context: CorpusContext) async -> ReachabilityGraph {
        let graph = ReachabilityGraph()

        await graph.detectRoots(
            declarations: result.declarations.declarations,
            context: context,
            configuration: configuration.rootDetection
        )

        await buildEdges(graph: graph, result: result, context: context)

        return graph
    }

    // MARK: - Edge building

    /// Compute reference edges in parallel and batch-insert them.
    private func buildEdges(
        graph: ReachabilityGraph,
        result: AnalysisResult,
        context: CorpusContext
    ) async {
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
        var sortedRefsMutable: [String: [Reference]] = [:]
        sortedRefsMutable.reserveCapacity(result.references.byFile.count)
        for (file, refs) in result.references.byFile {
            sortedRefsMutable[file] = refs.sorted { $0.location.line < $1.location.line }
        }
        let sortedRefsByFile = sortedRefsMutable

        let maxConcurrency = ProcessInfo.processInfo.activeProcessorCount

        let computedEdges = await ParallelProcessor.compactMap(
            Array(allDeclarations.enumerated()),
            maxConcurrency: maxConcurrency
        ) { entry -> [DependencyEdge]? in
            let edges = self.computeEdgesForDeclaration(
                entry.element,
                index: Int32(entry.offset),
                sortedRefsByFile: sortedRefsByFile,
                declByName: declByName
            )
            return edges.isEmpty ? nil : edges
        }

        await graph.addEdges(computedEdges.flatMap { $0 })

        if configuration.trackProtocolWitnesses {
            let witnessEdges = computeProtocolEdges(
                result: result,
                context: context,
                declByName: declByName
            )
            await graph.addEdges(witnessEdges)
        }
    }

    /// Compute edges for a single declaration (pure function): every
    /// reference inside the declaration's line range points at every
    /// same-named declaration (name-level over-approximation).
    private func computeEdgesForDeclaration(
        _ declaration: Declaration,
        index: Int32,
        sortedRefsByFile: [String: [Reference]],
        declByName: [String: [Int32]]
    ) -> [DependencyEdge] {
        var edges: [DependencyEdge] = []

        let scopeRefs = findReferencesInScope(
            declaration: declaration, sortedRefsByFile: sortedRefsByFile)

        for ref in scopeRefs {
            for target in findTargetDeclarations(for: ref, declarations: declByName) {
                let kind = mapReferenceContextToEdgeKind(ref.context)
                edges.append(DependencyEdge(from: index, to: target, kind: kind))
            }
        }

        // Type annotations reference their type names.
        if let typeAnnotation = declaration.typeAnnotation {
            for typeName in extractTypeNames(from: typeAnnotation) {
                for typeIndex in declByName[typeName] ?? [] {
                    edges.append(
                        DependencyEdge(from: index, to: typeIndex, kind: .typeReference))
                }
            }
        }

        return edges
    }

    /// References inside a declaration's file and line range: two binary
    /// searches over the file's line-sorted references bound the inclusive
    /// [start.line, end.line] subrange (same membership as the old linear
    /// filter, in line order instead of collection order).
    private func findReferencesInScope(
        declaration: Declaration,
        sortedRefsByFile: [String: [Reference]]
    ) -> ArraySlice<Reference> {
        guard let fileRefs = sortedRefsByFile[declaration.location.file] else {
            return []
        }
        let startLine = declaration.range.start.line
        let endLine = declaration.range.end.line
        let lower = fileRefs.partitionPoint { $0.location.line >= startLine }
        let upper = fileRefs.partitionPoint { $0.location.line > endLine }
        return fileRefs[lower..<upper]
    }

    /// Declaration indices a reference might be pointing to (by name, plus
    /// the qualifier of qualified references).
    private func findTargetDeclarations(
        for reference: Reference,
        declarations: [String: [Int32]]
    ) -> [Int32] {
        var targets: [Int32] = []

        if let matches = declarations[reference.identifier] {
            targets.append(contentsOf: matches)
        }

        if let qualifier = reference.qualifier,
            let qualifierDecls = declarations[qualifier]
        {
            targets.append(contentsOf: qualifierDecls)
        }

        return targets
    }

    private func mapReferenceContextToEdgeKind(_ context: ReferenceContext) -> DependencyKind {
        switch context {
        case .call:
            .call
        case .read, .write, .memberAccessBase, .memberAccessMember:
            .propertyAccess
        case .typeAnnotation:
            .typeReference
        case .inheritance:
            .inheritance
        case .genericConstraint:
            .genericConstraint
        case .keyPath:
            .keyPath
        case .attribute, .import, .pattern, .unknown:
            .typeReference
        }
    }

    /// Extract type names from a type annotation string.
    private func extractTypeNames(from typeAnnotation: String) -> [String] {
        var names: [String] = []

        let separators: [String] = ["[", "]", "<", ">", ",", ":", "(", ")", "->"]
        var cleaned =
            typeAnnotation
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "!", with: "")
        for separator in separators {
            cleaned = cleaned.replacingOccurrences(of: separator, with: " ")
        }

        for part in cleaned.split(separator: " ") {
            let name = String(part).trimmingCharacters(in: .whitespaces)
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
                    edges.append(
                        DependencyEdge(
                            from: protoIndex, to: requirement, kind: .protocolRequirement))
                }
            }

            for requirement in requirements {
                let requirementName = allDeclarations[Int(requirement)].name
                for witness in declByName[requirementName] ?? [] {
                    guard
                        isWitness(
                            allDeclarations[Int(witness)], ofProtocol: proto.name, context: context)
                    else { continue }
                    edges.append(
                        DependencyEdge(
                            from: requirement, to: witness, kind: .protocolRequirement))
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
        let graph = await extractor.buildGraph(from: result, context: context)

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
            .operator, .extension, .associatedtype:
            // Imports have their own pass; the rest have no rule —
            // name-level reference tracking cannot judge them reliably.
            false
        }
    }
}
