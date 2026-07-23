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
        let references = result.references
        let allDeclarations = result.declarations.declarations

        // Name → declarations lookup (immutable copy for Sendable capture).
        var declByNameMutable: [String: [Declaration]] = [:]
        for declaration in allDeclarations {
            declByNameMutable[declaration.name, default: []].append(declaration)
        }
        let declByName = declByNameMutable

        let maxConcurrency = ProcessInfo.processInfo.activeProcessorCount

        let computedEdges = await ParallelProcessor.compactMap(
            allDeclarations,
            maxConcurrency: maxConcurrency
        ) { declaration -> [DependencyEdge]? in
            let edges = self.computeEdgesForDeclaration(
                declaration,
                references: references,
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
        references: ReferenceIndex,
        declByName: [String: [Declaration]]
    ) -> [DependencyEdge] {
        var edges: [DependencyEdge] = []
        let declNode = DeclarationNode(declaration: declaration)

        let scopeRefs = findReferencesInScope(declaration: declaration, allRefs: references)

        for ref in scopeRefs {
            for target in findTargetDeclarations(for: ref, declarations: declByName) {
                let targetNode = DeclarationNode(declaration: target)
                let kind = mapReferenceContextToEdgeKind(ref.context)
                edges.append(DependencyEdge(from: declNode.id, to: targetNode.id, kind: kind))
            }
        }

        // Type annotations reference their type names.
        if let typeAnnotation = declaration.typeAnnotation {
            for typeName in extractTypeNames(from: typeAnnotation) {
                for typeDecl in declByName[typeName] ?? [] {
                    let targetNode = DeclarationNode(declaration: typeDecl)
                    edges.append(
                        DependencyEdge(from: declNode.id, to: targetNode.id, kind: .typeReference))
                }
            }
        }

        return edges
    }

    /// References inside a declaration's file and line range.
    private func findReferencesInScope(
        declaration: Declaration,
        allRefs: ReferenceIndex
    ) -> [Reference] {
        let fileRefs = allRefs.find(inFile: declaration.location.file)

        return fileRefs.filter { ref in
            ref.location.line >= declaration.range.start.line
                && ref.location.line <= declaration.range.end.line
        }
    }

    /// Declarations a reference might be pointing to (by name, plus the
    /// qualifier of qualified references).
    private func findTargetDeclarations(
        for reference: Reference,
        declarations: [String: [Declaration]]
    ) -> [Declaration] {
        var targets: [Declaration] = []

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
        declByName: [String: [Declaration]]
    ) -> [DependencyEdge] {
        var edges: [DependencyEdge] = []
        let protocols = result.declarations.find(kind: .protocol)
        guard !protocols.isEmpty else { return edges }

        // Requirements grouped by their protocol.
        var requirementsByProtocol: [String: [Declaration]] = [:]
        for declaration in result.declarations.declarations {
            guard let enclosing = context.nearestEnclosingType(of: declaration),
                enclosing.kind == .protocol,
                declaration.kind != .protocol
            else { continue }
            requirementsByProtocol[enclosing.name, default: []].append(declaration)
        }

        for proto in protocols {
            let protoNode = DeclarationNode(declaration: proto)

            if configuration.treatProtocolRequirementsAsRoot {
                for requirement in requirementsByProtocol[proto.name] ?? [] {
                    let requirementNode = DeclarationNode(declaration: requirement)
                    edges.append(
                        DependencyEdge(
                            from: protoNode.id, to: requirementNode.id, kind: .protocolRequirement))
                }
            }

            for requirement in requirementsByProtocol[proto.name] ?? [] {
                let requirementNode = DeclarationNode(declaration: requirement)
                for witness in declByName[requirement.name] ?? [] {
                    guard isWitness(witness, ofProtocol: proto.name, context: context) else {
                        continue
                    }
                    let witnessNode = DeclarationNode(declaration: witness)
                    edges.append(
                        DependencyEdge(
                            from: requirementNode.id, to: witnessNode.id, kind: .protocolRequirement))
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

    /// Detect unused code as the set of unreachable declarations.
    func detect(in result: AnalysisResult, context: CorpusContext) async -> [UnusedCode] {
        let extractor = DependencyExtractor(configuration: extractionConfiguration)
        let graph = await extractor.buildGraph(from: result, context: context)

        // BFS backend: forced by `useParallelBFS`, else auto-selected
        // against the node-count threshold.
        let nodeCount = await graph.nodeCount
        let runParallel = configuration.useParallelBFS ?? (nodeCount >= configuration.parallelBFSThreshold)

        let unreachable: [DeclarationNode]
        if runParallel {
            unreachable = await graph.computeUnreachableParallel()
        } else {
            unreachable = await graph.computeUnreachable()
        }

        return unreachable.compactMap { node -> UnusedCode? in
            let declaration = node.declaration

            guard shouldReport(declaration) else {
                return nil
            }

            let confidence = declaration.unusedConfidence(context: context)
            if confidence < configuration.minimumConfidence {
                return nil
            }

            return UnusedCode(
                declaration: declaration,
                reason: .neverReferenced,
                confidence: confidence,
                suggestion: "Unreachable from any entry point - consider removing '\(declaration.name)'"
            )
        }
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
