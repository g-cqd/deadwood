//  Lifted from SwiftStaticAnalysis (MIT) — UnusedCodeDetector/UnusedCodeDetector.swift.
//  Changes during the lift:
//  - IndexStoreDB import and the `.indexStore` arms are gone; `simple` and
//    `reachability` modes remain.
//  - file IO/parsing removed: the detector consumes an already-collected
//    `AnalysisResult` (the Analyzer owns reading and parsing).
//  - simple mode routes its skip decisions through the shared
//    `RootDetector`, so both modes agree on what an entry point is.

// MARK: - UnusedCodeDetector

/// Detects unused code in collected analysis facts.
struct UnusedCodeDetector: Sendable {
    /// Configuration for detection.
    let configuration: UnusedCodeConfiguration

    /// Pre-compiled ignore patterns for efficient matching.
    private let compiledIgnorePatterns: CompiledPatterns

    init(configuration: UnusedCodeConfiguration = .default) {
        self.configuration = configuration
        compiledIgnorePatterns = CompiledPatterns(configuration.ignoredPatterns)
    }

    /// Detect unused declarations in the analysis result, per the
    /// configured mode.
    func detectUnused(in result: AnalysisResult, context: CorpusContext) async -> [UnusedCode] {
        switch configuration.mode {
        case .simple:
            detectFromResult(result, context: context)

        case .reachability:
            await detectWithReachability(in: result, context: context)
        }
    }

    // MARK: - Reachability mode

    private func detectWithReachability(
        in result: AnalysisResult,
        context: CorpusContext
    ) async -> [UnusedCode] {
        let extractionConfig = DependencyExtractionConfiguration(
            rootDetection: configuration.rootDetection,
            treatProtocolRequirementsAsRoot: true,
            trackProtocolWitnesses: true
        )
        let reachabilityDetector = ReachabilityBasedDetector(
            configuration: configuration,
            extractionConfiguration: extractionConfig
        )
        return await reachabilityDetector.detect(in: result, context: context)
    }

    // MARK: - Simple mode

    /// Simple reference counting: a declaration is unused when no reference
    /// with its name exists anywhere in the analyzed sources. Fast and
    /// per-file sound, but blind to transitively dead clusters (a dead
    /// function referencing another keeps the second one "used").
    func detectFromResult(_ result: AnalysisResult, context: CorpusContext) -> [UnusedCode] {
        let referencedIdentifiers = result.references.uniqueIdentifiers
        let rootDetector = RootDetector(configuration: configuration.rootDetection)

        return result.declarations.declarations.compactMap { declaration -> UnusedCode? in
            guard shouldCheck(declaration, rootDetector: rootDetector, context: context) else {
                return nil
            }

            guard !referencedIdentifiers.contains(declaration.name) else { return nil }

            let confidence = declaration.unusedConfidence(context: context)
            guard confidence >= configuration.minimumConfidence else { return nil }

            let reason = determineReason(for: declaration, result: result)
            return UnusedCode(
                declaration: declaration,
                reason: reason,
                confidence: confidence,
                suggestion: "Consider removing unused \(declaration.kind.rawValue) '\(declaration.name)'"
            )
        }
    }

    /// Whether a declaration is even a candidate in simple mode.
    private func shouldCheck(
        _ declaration: Declaration,
        rootDetector: RootDetector,
        context: CorpusContext
    ) -> Bool {
        guard declaration.name != "_" else { return false }
        guard shouldCheckKind(declaration) else { return false }

        // Entry points, SwiftUI roots, operators, witnesses: the same
        // decisions reachability mode makes.
        guard rootDetector.rootReason(for: declaration, context: context) == nil else {
            return false
        }

        // Protocol requirements are kept alive by their protocol.
        guard !context.isProtocolRequirement(declaration) else { return false }

        guard !compiledIgnorePatterns.anyMatches(declaration.name) else { return false }

        return true
    }

    private func shouldCheckKind(_ declaration: Declaration) -> Bool {
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
            // Imports have their own rule; the rest have no rule —
            // name-level reference tracking cannot judge them reliably.
            false
        }
    }

    private func determineReason(
        for declaration: Declaration,
        result: AnalysisResult
    ) -> UnusedReason {
        switch declaration.kind {
        case .constant, .variable:
            let refs = result.references.find(identifier: declaration.name)
            let hasReads = refs.contains { $0.context == .read }
            if !hasReads, refs.contains(where: { $0.context == .write }) {
                return .onlyAssigned
            }
            return .neverReferenced

        case .import:
            return .importNotUsed

        default:
            return .neverReferenced
        }
    }

    // MARK: - Assign-only properties

    /// Stored properties whose every reference is a write: state maintained
    /// that nothing consumes. Conservative on purpose — any non-write
    /// reference context (reads, member accesses, patterns, key paths)
    /// counts as a potential read, because `object.property` cannot be
    /// classified as read or write at the syntax level.
    func detectAssignOnly(result: AnalysisResult, context: CorpusContext) -> [UnusedCode] {
        guard configuration.detectAssignOnly else { return [] }
        let rootDetector = RootDetector(configuration: configuration.rootDetection)

        return result.declarations.declarations.compactMap { declaration -> UnusedCode? in
            guard declaration.kind == .variable || declaration.kind == .constant else {
                return nil
            }
            guard declaration.name != "_" else { return nil }
            // Wrapper-synthesized accessors read the property invisibly.
            guard !declaration.hasImplicitUsageWrapper else { return nil }
            guard rootDetector.rootReason(for: declaration, context: context) == nil else {
                return nil
            }
            guard !context.isProtocolRequirement(declaration) else { return nil }
            guard !compiledIgnorePatterns.anyMatches(declaration.name) else { return nil }

            let refs = result.references.find(identifier: declaration.name)
            guard !refs.isEmpty else { return nil }  // Never referenced → unused-property.
            guard refs.allSatisfy({ $0.context == .write }) else { return nil }

            return UnusedCode(
                declaration: declaration,
                reason: .onlyAssigned,
                confidence: declaration.unusedConfidence(context: context),
                suggestion:
                    "Property '\(declaration.name)' is written but never read - remove it and its assignments"
            )
        }
    }

    // MARK: - Unused imports

    /// Syntax-level unused-import heuristic: without index data a reference
    /// like `URLSession` cannot be mapped back to `Foundation`, so this
    /// only checks module-qualified uses (`Foundation.NSNumber`) and bare
    /// references matching the module name. Strictly weaker than semantic
    /// resolution — reported at `.low` confidence behind an opt-in rule.
    func detectUnusedImports(result: AnalysisResult) -> [UnusedCode] {
        var unusedImports: [UnusedCode] = []

        let imports = result.declarations.find(kind: .import)
        guard !imports.isEmpty else { return unusedImports }

        for importDecl in imports {
            let moduleName = importDecl.name

            // `@_exported import` re-exports the module to every client:
            // the import IS the usage, so it is never flagged.
            if importDecl.attributes.contains("_exported") {
                continue
            }

            // Per-file check: an import in one file is not justified by a
            // qualified reference in another.
            let fileReferences = result.references.find(inFile: importDecl.location.file)
            let hasModuleReference = fileReferences.contains { reference in
                reference.identifier == moduleName || reference.qualifier == moduleName
            }

            if !hasModuleReference {
                unusedImports.append(
                    UnusedCode(
                        declaration: importDecl,
                        reason: .importNotUsed,
                        confidence: .low,
                        suggestion:
                            "Import '\(moduleName)' has no module-qualified reference in the analyzed sources."
                    ))
            }
        }

        return unusedImports
    }
}
