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

#if canImport(IndexStoreDB)
    import Foundation

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
            /// One-line index summary (symbol counts, resolution rate).
            let summary: String
        }

        /// Compute index-backed reachability. Throws only if the index cannot
        /// be opened — the caller then falls back to the syntax graph.
        func computeReachability(
            result: AnalysisResult,
            context: CorpusContext,
            rootConfiguration: RootDetectionConfiguration,
            productionMode: Bool,
            testScoped: [Bool],
            indexStorePath: String,
            analysisFiles: [String],
            allowsDirectoryCreation: Bool
        ) throws(IndexStoreError) -> Result {
            let reader = try IndexStoreReader(
                indexStorePath: indexStorePath,
                allowsDirectoryCreation: allowsDirectoryCreation
            )
            reader.pollForChanges()

            let graph = IndexBasedDependencyGraph(analysisFiles: analysisFiles)
            graph.build(from: reader)

            let declarations = result.declarations.declarations
            let declToUSR = Self.mapDeclarationsToUSRs(
                declarations: declarations, definitionNodes: graph.definitionNodes)

            // Declarations the index oracle must never flag, mirroring the
            // syntax graph's conservatism: locals (ambiguous line-mapping; the
            // dead-store pass owns them) and in-corpus protocol requirements /
            // witnesses (kept alive by the protocol, but invoked through
            // dispatch that leaves no by-name index reference).
            let forcedReachable = Self.forcedReachableIndices(
                declarations: declarations, context: context)
            // Forced declarations also SEED the BFS: their USRs join the root
            // set so the symbols they reference (an error case a witness throws,
            // a helper a default impl calls) propagate reachability and aren't
            // themselves left dangling as false positives.
            let forcedUSRs = Set(forcedReachable.compactMap { declToUSR[$0] })

            // With-test roots — deadwood's own rich root detection, projected
            // onto the USRs those roots resolve to, plus the forced seeds.
            let reachableWithTests = Self.reachableIndices(
                declarations: declarations,
                declToUSR: declToUSR,
                reachableUSRs: graph.reachableUSRs(
                    fromRootUSRs: Self.rootUSRs(
                        declarations: declarations,
                        declToUSR: declToUSR,
                        context: context,
                        configuration: rootConfiguration,
                        excludingTestScoped: nil
                    ).union(forcedUSRs)
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
                    reachableUSRs: graph.reachableUSRs(
                        fromRootUSRs: Self.rootUSRs(
                            declarations: declarations,
                            declToUSR: declToUSR,
                            context: context,
                            configuration: productionConfig,
                            excludingTestScoped: testScoped
                        ).union(forcedUSRs)
                    ),
                    forcedReachable: forcedReachable
                )
            }

            // Reference-count analyzer: keeps the lifted analyzer wired and
            // feeds the stderr summary.
            let analyzer = IndexStoreAnalyzer(reader: reader, files: analysisFiles)
            let zeroReference = analyzer.findUnusedSymbols().count
            let summary =
                "index: \(graph.definitionNodes.count) symbols in scope, "
                + "\(zeroReference) with zero index references; "
                + "\(declToUSR.count)/\(declarations.count) declarations resolved to USRs"

            return Result(
                reachableWithTests: reachableWithTests,
                reachableInProduction: reachableInProduction,
                summary: summary
            )
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
            var byNameFile: [String: [(line: Int, usr: String)]] = [:]
            for node in definitionNodes {
                guard let file = node.definitionFile, let line = node.definitionLine else { continue }
                byNameFile[nameKey(file: file, name: baseName(node.name)), default: []]
                    .append((line, node.usr))
            }

            var declToUSR: [Int: String] = [:]
            declToUSR.reserveCapacity(declarations.count)
            for (index, declaration) in declarations.enumerated() {
                let file = IndexBasedDependencyGraph.canonicalPath(declaration.location.file)
                let key = nameKey(file: file, name: declaration.name)
                guard let candidates = byNameFile[key], !candidates.isEmpty else { continue }
                let declLine = declaration.location.line
                guard
                    let best = candidates.min(by: {
                        abs($0.line - declLine) < abs($1.line - declLine)
                    })
                else { continue }
                if abs(best.line - declLine) <= lineMatchTolerance {
                    declToUSR[index] = best.usr
                }
            }
            return declToUSR
        }

        /// USRs of the declarations deadwood considers roots. `excludingTestScoped`
        /// (production mode) drops roots that live in test code.
        private static func rootUSRs(
            declarations: [Declaration],
            declToUSR: [Int: String],
            context: CorpusContext,
            configuration: RootDetectionConfiguration,
            excludingTestScoped testScoped: [Bool]?
        ) -> Set<String> {
            let detector = RootDetector(configuration: configuration)
            var roots = Set<String>()
            for (index, declaration) in declarations.enumerated() {
                if let testScoped, testScoped[index] { continue }
                guard detector.rootReason(for: declaration, context: context) != nil else { continue }
                if let usr = declToUSR[index] { roots.insert(usr) }
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
                let inCorpusConformances = context.conformances(ofTypeNamed: enclosing.name)
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
            String(name.prefix { $0 != "(" })
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
            guard let firstFile = files.first else { return cwd }
            var current = URL(fileURLWithPath: firstFile).deletingLastPathComponent()
            for _ in 0..<12 {
                let packageSwift = current.appendingPathComponent("Package.swift")
                if FileManager.default.fileExists(atPath: packageSwift.path) {
                    return current.path
                }
                if let contents = try? FileManager.default.contentsOfDirectory(atPath: current.path),
                    contents.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") })
                {
                    return current.path
                }
                let parent = current.deletingLastPathComponent()
                if parent.path == current.path { break }
                current = parent
            }
            return cwd
        }
    }
#endif
