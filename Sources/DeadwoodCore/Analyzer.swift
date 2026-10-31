public import CorpusScan
public import ProjectModel
import SourceCorpus
import SwiftParser
import SwiftSyntax
import SymbolFacts

#if canImport(IndexStoreDB)
    import IndexStoreSupport
#endif

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Entry point of the pipeline: reads each file with a bounded reader, scans
/// suppression directives, runs the detection engine, and assembles the
/// report.
///
/// Two shapes of analysis:
/// - ``analyze(files:)`` — the corpus path. Parses every file, then runs
///   reachability detection across the whole set: entry points (@main,
///   public API, @objc, SwiftUI roots, tests, ...) are roots, and anything
///   no root can reach is dead.
/// - ``analyze(source:path:)`` — single file, simple-mode semantics: only
///   declarations that are *effectively private to the file* can be judged
///   (an internal declaration may be used from any other file of its
///   module). Cross-file reachability needs ``analyze(files:)``.
public struct Analyzer: Sendable {
    /// Files above this cap are reported degraded rather than read into RAM.
    public static let sourceByteCap = 10 * 1024 * 1024

    public let configuration: Configuration

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    // MARK: - Corpus analysis

    /// Analyze a corpus of files. With `cache`, per-file artifacts (facts, directives, dataflow findings) are reused
    /// through analyzerkit's `CorpusScanner` (ADR-0011) when the file's content, the configuration and the build
    /// match; the corpus-wide graph/BFS and every rule always re-run, so findings can never go stale relative to rules
    /// or configuration.
    /// - Parameter reportScope: narrows the *report* to a set of files; nil
    ///   reports everything. Reachability is corpus-level either way — see
    ///   ``ProjectModel/ReportScope``.
    /// - Parameter projectFiles: Info.plists, storyboards, xibs and Xcode
    ///   project files; the types they name are entry points (see
    ///   ``SourceDiscovery/projectFiles(in:)``).
    public func analyze(
        files: [String],
        projectFiles: [String] = [],
        cache: CacheLocation? = nil,
        indexStore: IndexStoreOptions = .disabled,
        embeddingConfidence: Bool = false,
        embeddingBundle: String? = nil,
        reportScope: ReportScope? = nil
    ) async -> AnalysisReport {
        // Canonicalize before anything reads a path: `Finding.path` feeds the
        // fingerprint, and the corpus must not contain the same file twice
        // under two spellings (it would enter the graph twice).
        let files = SourcePath.canonicalized(files)
        let started = ContinuousClock.now

        var report = AnalysisReport()
        report.analyzedFileCount = files.count

        let deadBranchesEnabled = configuration.isEnabled(.deadBranch)
        let deadStoresEnabled = configuration.isEnabled(.deadStore)
        // The entire configuration and rule settings participate in the key.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let configurationData = try? encoder.encode(configuration)
        let cache = configurationData == nil ? nil : cache
        let salt = "utf8=strict;config=" + (configurationData.map { String(decoding: $0, as: UTF8.self) } ?? "")

        // Regions come from the project first (ADR-0024). The cache keeps only what the content says of a file's
        // region; the project's part changes without the file changing, so it is joined on every run.
        let classification = ProjectLayout.discover(paths: files).map(ProjectClassification.load) ?? .conventionsOnly
        let scan: CorpusScan<ExtractedArtifacts>
        do {
            scan = try await CorpusScanner.scan(
                paths: files, cache: cache,
                identity: CacheIdentity.current(tool: ToolInfo.name, version: ToolInfo.version), salt: salt,
                width: ParallelMode.safe.concurrencyConfiguration.maxConcurrentFiles
            ) { path, bytes in
                Self.extract(
                    bytes: bytes, path: path, deadBranchesEnabled: deadBranchesEnabled,
                    deadStoresEnabled: deadStoresEnabled)
            }
        } catch {
            // Abort, never truncate: deadwood decides "unused" by finding no reference anywhere, so a partial corpus
            // turns live declarations into false positives. The scanner does not touch the cache when cancelled.
            report.wasCancelled = true
            return report
        }
        report.cacheLoadFailure = scan.cacheLoadFailure
        let scanned = ContinuousClock.now

        var perFile: [FileArtifacts] = []
        var cacheHits = 0
        for file in scan.files {
            if let failure = file.failure {
                report.degradedFiles.append(
                    .init(path: file.path, detail: "read failed or exceeds size cap: \(failure)"))
                continue
            }
            guard let extracted = file.facts else { continue }
            guard let cached = extracted.artifacts else {
                report.degradedFiles.append(.init(path: file.path, detail: extracted.skipped ?? "not analysed"))
                continue
            }
            var artifacts = FileArtifacts(path: file.path, cached: cached)
            let region = classification.classify(
                file.path, content: CodeRegion(rawValue: artifacts.facts.contentRegion)
            )
            .region
            artifacts.facts.isGenerated = region.contains(.generated)
            artifacts.facts.isTestCode = region.contains(.test)
            perFile.append(artifacts)
            if file.cacheHit { cacheHits += 1 }
        }
        if cache != nil {
            report.cacheHits = cacheHits
            report.cacheMisses = perFile.count - cacheHits
        }
        report.classificationIssues = classification.issues(for: files)
        let analyzedPaths = perFile.map(\.path)

        // Cancellation may have landed inside extraction: SCCP, liveness and frontier expansion break out of their
        // fixpoint loops, so their outputs are truncated, not merely late. The scanner throws then, and does not
        // persist; this catches a cancellation that lands after it.
        if Task.isCancelled {
            report.findings = []
            report.outOfScope = []
            report.suppressed = []
            report.wasCancelled = true
            return report
        }

        // Aggregate the corpus and run detection.
        let engineConfig = engineConfiguration(mode: .reachability)
        let result = StaticAnalyzer.aggregate(perFile.map(\.facts), files: analyzedPaths)
        let entryPoints = Self.systemEntryPoints(in: projectFiles)
        report.notes.append(contentsOf: entryPoints.notes)
        let context = CorpusContext(result: result, systemEntryPoints: entryPoints.typeNames)
        let detector = UnusedCodeDetector(configuration: engineConfig)

        // Reachability is the one stage the index can resolve more precisely.
        // Default (index disabled) is byte-identical to the syntax path; index
        // mode swaps only this oracle, and any failure falls back to it.
        let reachability = await reachabilityUnused(
            result: result,
            context: context,
            engineConfig: engineConfig,
            files: analyzedPaths,
            detector: detector,
            indexStore: indexStore
        )
        report.notes.append(contentsOf: reachability.notes)
        var unused = reachability.unused
        unused = UnusedCodeFilter(configuration: .sensibleDefaults).filter(unused)
        if engineConfig.detectImports {
            unused.append(contentsOf: detector.detectUnusedImports(result: result))
        }
        unused.append(contentsOf: detector.detectAssignOnly(result: result, context: context))
        unused.append(contentsOf: perFile.flatMap(\.deadBranches))
        report.notes.append(
            contentsOf: Self.dropGenerated(
                from: &unused, result: result, regionSelection: engineConfig.regionSelection))

        // Surface per-file degraded-analysis notes (e.g. over-bound
        // functions the dead-branch pass skipped): the rest of the file was
        // analyzed, so none of them marks the file skipped.
        for artifacts in perFile {
            for note in artifacts.degraded {
                report.degradedFiles.append(.init(path: artifacts.path, detail: note, skipped: false))
            }
        }

        // Map to findings and apply per-file suppression tables.
        let mapper = FindingMapper(configuration: configuration, mode: .reachability)
        let findings = mapper.findings(from: unused, context: context)
        let tables = Dictionary(
            perFile.map { ($0.path, SuppressionTable(directives: $0.directives)) },
            uniquingKeysWith: { first, _ in first }
        )
        for finding in findings {
            if let reason = tables[finding.path]?.suppression(for: finding.rule, line: finding.line) {
                report.suppressed.append(.init(finding: finding, reason: reason))
            } else if let reportScope, !reportScope.contains(finding) {
                // Kept, not dropped: the count stays visible in the summary and
                // `--format json` still carries them. Scope is applied after
                // suppression so suppression debt keeps counting the whole
                // corpus.
                report.outOfScope.append(finding)
            } else {
                report.findings.append(finding)
            }
        }
        report.findings.sort()
        report.outOfScope.sort()

        if embeddingConfidence {
            report = await annotateEmbeddingConfidence(
                report, unused: unused,
                sourcesByPath: Self.sources(of: report.findings),
                bundlePath: embeddingBundle)
        }

        // Same guard after detection: reachability drains frontiers that
        // truncate on cancellation, and a partial reachable set reports every
        // node beyond the truncation as unused.
        if Task.isCancelled {
            report.findings = []
            report.outOfScope = []
            report.suppressed = []
            report.wasCancelled = true
            return report
        }

        // Anchor fingerprints to the repository, not to this machine's checkout path
        // or to whether the caller remembered --relative-to. Display is a separate
        // concern, handled by PathPresentation.
        if let root = RepositoryRoot.common(of: analyzedPaths) {
            report = report.fingerprintsAnchored(to: root)
        }
        report.timings = [
            "scan": Self.seconds(scanned - started), "detect": Self.seconds(ContinuousClock.now - scanned),
        ]
        return report
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    // MARK: - Generated code

    /// Removes the results located in generated files (dead branches; their
    /// declarations are roots and never reach here), and returns one note
    /// per generated file with declarations nothing outside it names.
    /// - Complexity: O(*g* · *r*) for *g* generated declarations and *r*
    ///   references per name.
    static func dropGenerated(
        from unused: inout [UnusedCode], result: AnalysisResult, regionSelection: RegionSelection
    ) -> [String] {
        guard !result.generatedFiles.isEmpty else { return [] }
        // --include generated keeps them, tagged, as ordinary findings
        // instead of withholding them — worth doing deliberately when a
        // generator's own template, not just its output, needs pruning.
        if regionSelection.isIncluded(.generated) {
            unused = unused.map { item in
                guard result.generatedFiles.contains(item.declaration.location.file) else { return item }
                return UnusedCode(
                    declaration: item.declaration,
                    reason: item.reason,
                    confidence: item.confidence,
                    suggestion: item.suggestion,
                    detail: item.detail,
                    regionTag: CodeRegion(rawValue: item.regionTag).union(.generated)
                )
            }
            return []
        }
        unused.removeAll { result.generatedFiles.contains($0.declaration.location.file) }
        let judged: Set<DeclarationKind> = [
            .function, .method, .variable, .constant, .class, .struct, .enum, .actor, .enumCase,
        ]
        var unnamed: [String: Int] = [:]
        for declaration in result.declarations.declarations
        where judged.contains(declaration.kind) && result.generatedFiles.contains(declaration.location.file) {
            let file = declaration.location.file
            let namedElsewhere = result.references.find(identifier: declaration.name)
                .contains { $0.location.file != file }
            if !namedElsewhere {
                unnamed[file, default: 0] += 1
            }
        }
        return unnamed.sorted { $0.key < $1.key }.map { file, count in
            "\(ToolInfo.name): generated file \(file) has \(count) declaration(s) nothing outside it names"
        }
    }

    // MARK: - System entry points

    /// Project files above this cap are skipped with a note.
    static let projectFileByteCap = 32 * 1024 * 1024

    /// The type names the project files make entry points, plus one note per
    /// file that could not be read.
    static func systemEntryPoints(in projectFiles: [String]) -> (typeNames: Set<String>, notes: [String]) {
        var typeNames: Set<String> = []
        var notes: [String] = []
        for path in projectFiles where SystemEntryPoints.isProjectFile(path) {
            guard let data = try? BoundedFileReader.read(path: path, cap: projectFileByteCap) else {
                notes.append("\(ToolInfo.name): project file \(path) could not be read; its entry points are unknown")
                continue
            }
            let contents = String(decoding: data, as: UTF8.self)
            for entryPoint in SystemEntryPoints.scan(path: path, contents: contents) {
                typeNames.insert(entryPoint.typeName)
            }
        }
        return (typeNames, notes)
    }

    // MARK: - Reachability oracle (syntax vs index)

    /// Compute the reachability-derived unused set, plus any stderr notes.
    /// Index disabled → today's syntax reachability, byte-identical. Index
    /// enabled → the index oracle when an index resolves, else the syntax
    /// oracle with a fallback note. Never hard-fails on a missing index.
    private func reachabilityUnused(
        result: AnalysisResult,
        context: CorpusContext,
        engineConfig: UnusedCodeConfiguration,
        files: [String],
        detector: UnusedCodeDetector,
        indexStore: IndexStoreOptions
    ) async -> (unused: [UnusedCode], notes: [String]) {
        guard indexStore.enabled else {
            return (await detector.detectUnused(in: result, context: context), [])
        }

        #if canImport(IndexStoreDB)
            return await indexBackedUnused(
                result: result,
                context: context,
                engineConfig: engineConfig,
                files: files,
                detector: detector,
                indexStore: indexStore
            )
        #else
            // IndexStoreDB isn't available on this platform (Linux): honor the
            // opt-in with a clear note, then run the syntax oracle.
            let syntax = await detector.detectUnused(in: result, context: context)
            return (
                syntax,
                [
                    "\(ToolInfo.name): warning: --index-store is macOS-only; falling back to name-based "
                        + "reachability on this platform, which can conflate same-named declarations across "
                        + "modules. Run the analysis on macOS to use the index store."
                ]
            )
        #endif
    }

    #if canImport(IndexStoreDB)
        /// The macOS index path: discover/open the index, run the bridge, and
        /// feed the reachability report tail. Any resolution or read failure
        /// degrades to the syntax oracle with a note.
        private func indexBackedUnused(
            result: AnalysisResult,
            context: CorpusContext,
            engineConfig: UnusedCodeConfiguration,
            files: [String],
            detector: UnusedCodeDetector,
            indexStore: IndexStoreOptions
        ) async -> (unused: [UnusedCode], notes: [String]) {
            let cwd = FileManager.default.currentDirectoryPath
            let projectRoot = IndexProjectLocator.projectRoot(for: files, fallback: cwd)
            let manager = IndexStoreFallbackManager(
                configuration: FallbackConfiguration(autoBuild: indexStore.autoBuild))
            let environment = ProcessInfo.processInfo.environment
            let cacheRoot =
                indexStore.cacheRoot
                ?? CacheLocation.defaultRoot(
                    tool: ToolInfo.name, environment: environment, home: environment["HOME"] ?? "/tmp")
            let outcome = await manager.resolveIndexStore(
                projectRoot: projectRoot,
                sourceFiles: files,
                explicitPath: indexStore.explicitPath,
                cacheRoot: cacheRoot
            )

            switch outcome {
            case .fallback(let reason):
                let syntax = await detector.detectUnused(in: result, context: context)
                return (syntax, ["\(ToolInfo.name): \(reason.description)"])

            case .index(let reader, let stale):
                let path = reader.indexStorePath
                let declarations = result.declarations.declarations
                let productionMode = engineConfig.productionMode
                let testScoped =
                    productionMode
                    ? TestScopeClassifier(testsGlob: engineConfig.testsGlob)
                        .classify(declarations: declarations, context: context)
                    : []

                let coverage = reader.session.coverage
                let reach = await IndexReachabilityBridge().computeReachability(
                    result: result,
                    context: context,
                    configuration: engineConfig,
                    rootConfiguration: engineConfig.rootDetection,
                    productionMode: productionMode,
                    testScoped: testScoped,
                    reader: reader,
                    analysisFiles: files,
                    uncoveredFiles: coverage.paths(.notIndexed) + coverage.paths(.changedSinceBuild),
                    verbose: indexStore.verbose
                )

                // A discovered index that resolves NONE of the analyzed
                // declarations does not cover this corpus (wrong project
                // root, unbuilt files). Using it would mark everything
                // reachable and silently hide real dead code — fall back.
                guard reach.resolvedCount > 0 || declarations.isEmpty else {
                    let syntax = await detector.detectUnused(in: result, context: context)
                    return (
                        syntax,
                        [
                            "\(ToolInfo.name): warning: index at \(path) does not cover the analyzed "
                                + "files (0 declarations resolved); falling back to name-based reachability, "
                                + "which can conflate same-named declarations across modules. Pass the index "
                                + "store built from this project (for an Xcode project, its DerivedData "
                                + "Index.noindex/DataStore) after building or testing it."
                        ]
                    )
                }

                let extractionConfig = DependencyExtractionConfiguration(
                    rootDetection: engineConfig.rootDetection, treatProtocolRequirementsAsRoot: true)
                let tail = ReachabilityBasedDetector(
                    configuration: engineConfig, extractionConfiguration: extractionConfig)
                var unused = reach.deadGroupResults
                if productionMode, let reachableInProduction = reach.reachableInProduction {
                    unused.append(
                        contentsOf: tail.onlyTestedResults(
                            declarations: declarations,
                            reachableWithTests: reach.reachableWithTests,
                            reachableInProduction: reachableInProduction,
                            testScoped: testScoped,
                            context: context
                        ))
                }

                // Region notes are an independent pass over the syntax
                // name-graph (`DependencyExtractor.regionOnlyResults`
                // needs no reachability set of its own), so the index
                // oracle gets them exactly as the syntax oracle does,
                // with no index-specific region graph to build.
                if (engineConfig.detectPreviewOnly || engineConfig.detectDebugOnly),
                    context.hasCodeRegions
                {
                    let (_, leveledEdges) = await DependencyExtractor(configuration: extractionConfig)
                        .buildGraph(from: result, context: context, recordingRegionLevels: true)
                    if let leveledEdges {
                        unused.append(
                            contentsOf: tail.regionOnlyResults(
                                edges: leveledEdges, declarations: declarations, context: context))
                    }
                }

                // A file the index never saw, or saw before it last
                // changed, cannot support a verdict: the edges it would
                // draw are missing or describe code that no longer
                // exists. Drop findings anchored there rather than
                // report them from stale or absent data; the note below
                // already says which files and why.
                if !stale.isEmpty {
                    let staleFiles = Set(stale.map { IndexBasedDependencyGraph.canonicalPath($0) })
                    unused.removeAll {
                        staleFiles.contains(IndexBasedDependencyGraph.canonicalPath($0.declaration.location.file))
                    }
                }

                // The advice follows the coverage class (ADR-0005 item 4): a file with no unit was not built by this
                // scheme, a file newer than its unit changed since the build.
                var notes = ["\(ToolInfo.name): --index-store active at \(path) — \(reach.summary)"]
                let unbuilt = coverage.paths(.notIndexed).count
                let changed = coverage.paths(.changedSinceBuild).count
                if !stale.isEmpty, unbuilt > 0 {
                    notes.append(
                        "\(ToolInfo.name): the index has no unit for \(unbuilt) file(s), not built by this scheme or not "
                            + "built yet; skipping their declarations, whose uses still count by name — build the "
                            + "scheme that compiles them")
                }
                if !stale.isEmpty, changed > 0 {
                    notes.append(
                        "\(ToolInfo.name): index is stale for \(changed) file(s) changed since the build; skipping their "
                            + "declarations, whose uses still count by name — re-run the build")
                }
                return (unused, notes)
            }
        }
    #endif

    // MARK: - Experimental embedding-confidence annotation

    /// Annotate each finding's note with a kNN semantic-anomaly score over the
    /// flagged declarations' snippets. Experimental: it never changes which
    /// findings fire, only appends a confidence hint. The scoring model is
    /// whatever ``EmbeddingProviderSelection`` resolves — an
    /// `--embedding-bundle`, a model shipped next to the binary, the on-device
    /// NL asset, or the deterministic fallback — and its name rides along in
    /// every annotation. No-ops (with a note) where NaturalLanguage is absent.
    private func annotateEmbeddingConfidence(
        _ report: AnalysisReport,
        unused: [UnusedCode],
        sourcesByPath: [String: String],
        bundlePath: String?
    ) async -> AnalysisReport {
        #if canImport(NaturalLanguage)
            var report = report
            guard report.findings.count > 1 else {
                report.notes.append(
                    "\(ToolInfo.name): --experimental-embedding-confidence needs >1 finding to score; skipped")
                return report
            }

            // Declaration snippet by location key, from the engine candidates.
            var rangeByKey: [String: SourceRange] = [:]
            for item in unused {
                rangeByKey[Self.locationKey(item.declaration.location)] = item.declaration.range
            }

            let snippets = report.findings.map { finding -> String in
                let key = "\(finding.path):\(finding.line):\(finding.column)"
                let source = sourcesByPath[finding.path] ?? ""
                return Self.snippet(from: source, range: rangeByKey[key], line: finding.line)
            }

            let (provider, selectionNotes) = await EmbeddingProviderSelection.resolve(
                bundlePath: bundlePath)
            report.notes.append(contentsOf: selectionNotes)
            let providerName = provider.providerName
            let scores = await EmbeddingConfidence().anomalyScores(
                snippets: snippets, provider: provider)

            guard !scores.isEmpty else {
                report.notes.append(
                    "\(ToolInfo.name): --experimental-embedding-confidence produced no score "
                        + "(\(providerName) unavailable); notes unchanged")
                return report
            }

            report.findings = report.findings.enumerated().map { index, finding in
                guard let score = scores[index] else { return finding }
                let percent = Int((score * 100).rounded())
                let annotated =
                    (finding.note.map { "\($0); " } ?? "")
                    + "embedding-confidence: \(percent)% anomaly [experimental, \(providerName)]"
                return Finding(
                    rule: finding.rule, severity: finding.severity, path: finding.path,
                    line: finding.line, column: finding.column, message: finding.message,
                    note: annotated, confidence: finding.confidence)
            }
            report.notes.append(
                "\(ToolInfo.name): --experimental-embedding-confidence annotated "
                    + "\(scores.count) finding(s) via \(providerName)")
            return report
        #else
            var report = report
            report.notes.append(
                "\(ToolInfo.name): --experimental-embedding-confidence is unavailable on this "
                    + "platform (requires NaturalLanguage)")
            return report
        #endif
    }

    #if canImport(NaturalLanguage)
        private static func locationKey(_ location: SourceLocation) -> String {
            "\(location.file):\(location.line):\(location.column)"
        }

        /// The declaration's source text (bounded), or the single finding line
        /// when the range is unknown.
        private static func snippet(from source: String, range: SourceRange?, line: Int) -> String {
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            guard !lines.isEmpty else { return "" }
            let startLine: Int
            let endLine: Int
            if let range {
                startLine = range.start.line
                endLine = min(range.end.line, range.start.line + 40)  // bound huge decls
            } else {
                startLine = line
                endLine = line
            }
            let lower = max(0, startLine - 1)
            let upper = min(lines.count, endLine)
            guard lower < upper else { return String(lines[min(lower, lines.count - 1)]) }
            return lines[lower..<upper].joined(separator: "\n")
        }
    #endif

    // MARK: - Single-file analysis

    public func analyze(source: String, path: String) -> AnalysisReport {
        // Runs on the caller's stack: the depth guard bounds the walk, but a caller analysing generated code nested
        // close to the limit should prefer `analyze(files:)`, which walks on a large stack.
        guard
            let artifacts = Self.collectArtifacts(
                path: path,
                source: source,
                deadBranchesEnabled: configuration.isEnabled(.deadBranch),
                deadStoresEnabled: configuration.isEnabled(.deadStore)
            )
        else {
            var report = AnalysisReport()
            report.analyzedFileCount = 1
            report.degradedFiles = [Self.tooDeep(path)]
            return report
        }
        let result = StaticAnalyzer.aggregate([artifacts.facts], files: [path])
        let context = CorpusContext(result: result)

        let engineConfig = engineConfiguration(mode: .simple)
        let detector = UnusedCodeDetector(configuration: engineConfig)

        var unused = detector.detectFromResult(result, context: context)
        unused = UnusedCodeFilter(configuration: .sensibleDefaults).filter(unused)
        if engineConfig.detectImports {
            unused.append(contentsOf: detector.detectUnusedImports(result: result))
        }
        unused.append(contentsOf: detector.detectAssignOnly(result: result, context: context))
        unused.append(contentsOf: artifacts.deadBranches)

        let mapper = FindingMapper(configuration: configuration, mode: .simple)
        let findings = mapper.findings(from: unused, context: context)

        var report = AnalysisReport()
        report.analyzedFileCount = 1
        for note in artifacts.degraded {
            report.degradedFiles.append(.init(path: path, detail: note, skipped: false))
        }
        let table = SuppressionTable(directives: artifacts.directives)
        for finding in findings {
            if let reason = table.suppression(for: finding.rule, line: finding.line) {
                report.suppressed.append(.init(finding: finding, reason: reason))
            } else {
                report.findings.append(finding)
            }
        }
        report.findings.sort()
        return report
    }

    // MARK: - Shared plumbing

    /// One file's extraction as the cache stores it: what one parse produces, or why the file was not analysed (over
    /// the size cap, not UTF-8, nested too deeply), so a cached file is never parsed again only to fail again.
    static func extract(
        bytes: [UInt8], path: String, deadBranchesEnabled: Bool, deadStoresEnabled: Bool
    ) -> ExtractedArtifacts {
        guard bytes.count <= sourceByteCap else {
            // Worded as the release worded it, through the configuration reader's error.
            let error = DeadwoodError.configurationInvalid(path: path, detail: "exceeds \(sourceByteCap) byte cap")
            return ExtractedArtifacts(skipped: "read failed or exceeds size cap: \(error)")
        }
        // Swift sources are UTF-8. Repairing invalid bytes would analyze text that is not in the file, and hide the
        // file from the count of skipped files.
        guard let source = String(validating: bytes, as: UTF8.self) else {
            return ExtractedArtifacts(skipped: "not valid UTF-8")
        }
        // Parsing and every walk of the tree recurse once per level: a tree nested past the limit is skipped, not
        // walked (analyzerkit roadmap 0041).
        guard
            let artifacts = collectArtifacts(
                path: path, source: source, deadBranchesEnabled: deadBranchesEnabled,
                deadStoresEnabled: deadStoresEnabled)
        else { return ExtractedArtifacts(skipped: tooDeep(path).detail) }
        return ExtractedArtifacts(artifacts: CachedFileArtifacts(artifacts))
    }

    /// The text of each file a finding lies in, read again for the opt-in
    /// embedding pass rather than held for the whole run. A file that can no
    /// longer be read is left out, and its findings go unscored.
    private static func sources(of findings: [Finding]) -> [String: String] {
        var sources: [String: String] = [:]
        for path in Set(findings.map(\.path)) {
            guard let data = try? BoundedFileReader.read(path: path, cap: sourceByteCap),
                let source = String(validating: data, as: UTF8.self)
            else { continue }
            sources[path] = source
        }
        return sources
    }

    /// Everything derived from one file in a single parse: facts for the
    /// corpus, the suppression directives, per-function dead branches, and
    /// any degraded-analysis notes (e.g. an over-bound function the
    /// dead-branch pass skipped). This is exactly the cacheable unit.
    fileprivate struct FileArtifacts: Sendable {
        let path: String
        var facts: FileAnalysisResult
        let directives: [SuppressionDirective]
        let deadBranches: [UnusedCode]
        let degraded: [String]

        init(
            path: String,
            facts: FileAnalysisResult,
            directives: [SuppressionDirective],
            deadBranches: [UnusedCode],
            degraded: [String]
        ) {
            self.path = path
            self.facts = facts
            self.directives = directives
            self.deadBranches = deadBranches
            self.degraded = degraded
        }

        init(path: String, cached: CachedFileArtifacts) {
            self.path = path
            facts = cached.facts
            directives = cached.directives
            deadBranches = cached.deadBranches
            degraded = cached.degraded
        }
    }

    /// The skipped-file entry for a tree nested past ``SyntaxDepth/defaultLimit``.
    private static func tooDeep(_ path: String) -> AnalysisReport.DegradedFile {
        .init(path: path, detail: "nested deeper than \(SyntaxDepth.defaultLimit) levels; not analysed")
    }

    /// The file's artifacts, or nil when its tree nests past ``SyntaxDepth/defaultLimit``: every walk below
    /// recurses once per level. Depth is measured after folding, which turns a flat `a + b + …` into a nested tree.
    private static func collectArtifacts(
        path: String,
        source: String,
        deadBranchesEnabled: Bool,
        deadStoresEnabled: Bool
    ) -> FileArtifacts? {
        // One SourceLocationConverter per file: the directive scanner, both
        // fact collectors, and the CFG builder all share this line table.
        let tree = foldedTree(Parser.parse(source: source))
        if SyntaxDepth.exceeds(tree) { return nil }
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        let directives = DirectiveScanner.scan(tree: tree, converter: converter)
        let facts = StaticAnalyzer().collectFacts(tree: tree, file: path, converter: converter)
        let deadBranchOutput =
            deadBranchesEnabled || deadStoresEnabled
            ? DeadBranchPass.run(
                tree: tree,
                file: path,
                converter: converter,
                includeDeadBranches: deadBranchesEnabled,
                includeDeadStores: deadStoresEnabled
            )
            : DeadBranchPass.Output()
        return FileArtifacts(
            path: path,
            facts: facts,
            directives: directives,
            deadBranches: deadBranchOutput.findings,
            degraded: deadBranchOutput.degraded
        )
    }

    /// Derive the engine configuration from the user-facing rule toggles.
    private func engineConfiguration(mode: DetectionMode) -> UnusedCodeConfiguration {
        let wantsPublicApi = configuration.isEnabled(.unusedPublicApi)
        var engine = UnusedCodeConfiguration(
            detectVariables: configuration.isEnabled(.unusedProperty) || wantsPublicApi,
            detectFunctions: configuration.isEnabled(.unusedFunction) || wantsPublicApi,
            detectTypes: configuration.isEnabled(.unusedType) || wantsPublicApi,
            detectImports: configuration.isEnabled(.unusedImport),
            detectAssignOnly: configuration.isEnabled(.assignOnlyProperty),
            // Production's two-pass reachability only exists in corpus mode;
            // single-file analysis cannot see the tests.
            productionMode: mode == .reachability && configuration.isProductionMode
                && configuration.isEnabled(.referencedOnlyByTests),
            testsGlob: configuration.testsGlob,
            mode: mode,
            minimumConfidence: .low,
            treatPublicAsRoot: !wantsPublicApi,
            treatVisibleOutsideFileAsRoot: mode == .simple
        )
        // Region reachability needs the whole corpus, like production mode.
        engine.detectPreviewOnly = mode == .reachability && configuration.isEnabled(.previewOnly)
        engine.detectDebugOnly = mode == .reachability && configuration.isEnabled(.debugOnly)
        engine.regionSelection = (try? configuration.regionSelection()) ?? .none
        return engine
    }
}

// MARK: - Cache bridging

extension CachedFileArtifacts {
    /// Snapshot the cacheable parts of one file's artifacts.
    fileprivate init(_ artifacts: Analyzer.FileArtifacts) {
        self.init(
            facts: artifacts.facts,
            directives: artifacts.directives,
            deadBranches: artifacts.deadBranches,
            degraded: artifacts.degraded
        )
    }
}
