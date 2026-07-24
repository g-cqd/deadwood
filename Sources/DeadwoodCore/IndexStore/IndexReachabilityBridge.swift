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

            // With-test roots — deadwood's own rich root detection, projected
            // onto the USRs those roots resolve to.
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
                    )
                )
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
                        )
                    )
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
        /// are conservatively reachable so an index coverage gap can never
        /// manufacture a false "unused" verdict.
        private static func reachableIndices(
            declarations: [Declaration],
            declToUSR: [Int: String],
            reachableUSRs: Set<String>
        ) -> Set<Int> {
            var reachable = Set<Int>()
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
