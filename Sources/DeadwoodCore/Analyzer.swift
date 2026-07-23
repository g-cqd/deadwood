public import Foundation
import SwiftParser
import SwiftSyntax

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

    /// Analyze a corpus of files. With `cacheURL`, per-file artifacts
    /// (facts, directives, dataflow findings) are reused when the file's
    /// content fingerprint matches; the corpus-wide graph/BFS and every
    /// rule always re-run, so findings can never go stale relative to rules
    /// or configuration.
    public func analyze(files: [String], cacheURL: URL? = nil) async -> AnalysisReport {
        var report = AnalysisReport()

        let deadBranchesEnabled = configuration.isEnabled(.deadBranch)
        let deadStoresEnabled = configuration.isEnabled(.deadStore)
        // Cached artifacts depend on which CFG passes ran — salt the
        // fingerprint so a rule toggle can never serve stale dataflow
        // findings.
        let salt = "branches=\(deadBranchesEnabled);stores=\(deadStoresEnabled)"
        let snapshot = cacheURL.map(FactsCache.load(url:)) ?? FactsCache()

        // Read every file up front (bounded); degraded files are reported,
        // never silently skipped.
        var sources: [(path: String, source: String, fingerprint: String)] = []
        sources.reserveCapacity(files.count)
        for path in files {
            if Task.isCancelled { break }
            report.analyzedFileCount += 1
            let data: Data
            do {
                data = try BoundedFileReader.read(path: path, cap: Self.sourceByteCap)
            } catch {
                report.degradedFiles.append(
                    .init(path: path, detail: "read failed or exceeds size cap: \(error)")
                )
                continue
            }
            sources.append(
                (
                    path,
                    String(decoding: data, as: UTF8.self),
                    FactsCache.fingerprint(of: data, salt: salt)
                ))
        }

        // Parse + collect facts + scan directives per file, in parallel;
        // fingerprint-matched files come from the cache snapshot instead.
        let engineConfig = engineConfiguration(mode: .reachability)
        let concurrency = ParallelMode.safe.concurrencyConfiguration
        let outcomes = await ParallelProcessor.map(
            sources,
            maxConcurrency: concurrency.maxConcurrentFiles
        ) { entry -> (artifacts: FileArtifacts, cacheHit: Bool) in
            if let cached = snapshot.artifacts(for: entry.path, fingerprint: entry.fingerprint) {
                return (FileArtifacts(path: entry.path, cached: cached), true)
            }
            let artifacts = Self.collectArtifacts(
                path: entry.path,
                source: entry.source,
                deadBranchesEnabled: deadBranchesEnabled,
                deadStoresEnabled: deadStoresEnabled
            )
            return (artifacts, false)
        }
        let perFile = outcomes.map(\.artifacts)
        report.cacheHits = outcomes.count(where: \.cacheHit)
        report.cacheMisses = outcomes.count - report.cacheHits

        // Persist a cache rebuilt from ONLY this run's files: absent files
        // are pruned, and the cache stays shaped to the project.
        if let cacheURL {
            var freshCache = FactsCache()
            for (source, outcome) in zip(sources, outcomes) {
                freshCache.update(
                    path: source.path,
                    fingerprint: source.fingerprint,
                    artifacts: CachedFileArtifacts(outcome.artifacts)
                )
            }
            freshCache.persist(url: cacheURL)
        }

        // Aggregate the corpus and run detection.
        let result = StaticAnalyzer.aggregate(perFile.map(\.facts), files: sources.map(\.path))
        let context = CorpusContext(result: result)
        let detector = UnusedCodeDetector(configuration: engineConfig)

        var unused = await detector.detectUnused(in: result, context: context)
        unused = UnusedCodeFilter(configuration: .sensibleDefaults).filter(unused)
        if engineConfig.detectImports {
            unused.append(contentsOf: detector.detectUnusedImports(result: result))
        }
        unused.append(contentsOf: detector.detectAssignOnly(result: result, context: context))
        unused.append(contentsOf: perFile.flatMap(\.deadBranches))

        // Surface per-file degraded-analysis notes (e.g. over-bound
        // functions the dead-branch pass skipped).
        for artifacts in perFile {
            for note in artifacts.degraded {
                report.degradedFiles.append(.init(path: artifacts.path, detail: note))
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
            } else {
                report.findings.append(finding)
            }
        }
        report.findings.sort()
        return report
    }

    // MARK: - Single-file analysis

    public func analyze(source: String, path: String) -> AnalysisReport {
        let artifacts = Self.collectArtifacts(
            path: path,
            source: source,
            deadBranchesEnabled: configuration.isEnabled(.deadBranch),
            deadStoresEnabled: configuration.isEnabled(.deadStore)
        )
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
            report.degradedFiles.append(.init(path: path, detail: note))
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

    /// Everything derived from one file in a single parse: facts for the
    /// corpus, the suppression directives, per-function dead branches, and
    /// any degraded-analysis notes (e.g. an over-bound function the
    /// dead-branch pass skipped). This is exactly the cacheable unit.
    fileprivate struct FileArtifacts: Sendable {
        let path: String
        let facts: FileAnalysisResult
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

    private static func collectArtifacts(
        path: String,
        source: String,
        deadBranchesEnabled: Bool,
        deadStoresEnabled: Bool
    ) -> FileArtifacts {
        // One SourceLocationConverter per file: the directive scanner, both
        // fact collectors, and the CFG builder all share this line table.
        let tree = foldedTree(Parser.parse(source: source))
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
        return UnusedCodeConfiguration(
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
