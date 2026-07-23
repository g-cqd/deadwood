import Foundation
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

    public func analyze(files: [String]) async -> AnalysisReport {
        var report = AnalysisReport()

        // Read every file up front (bounded); degraded files are reported,
        // never silently skipped.
        var sources: [(path: String, source: String)] = []
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
            sources.append((path, String(decoding: data, as: UTF8.self)))
        }

        // Parse + collect facts + scan directives per file, in parallel.
        let engineConfig = engineConfiguration(mode: .reachability)
        let concurrency = ParallelMode.safe.concurrencyConfiguration
        let perFile = await ParallelProcessor.map(
            sources,
            maxConcurrency: concurrency.maxConcurrentFiles
        ) { entry in
            Self.collectArtifacts(
                path: entry.path,
                source: entry.source,
                deadBranchesEnabled: self.configuration.isEnabled(.deadBranch)
            )
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
            perFile.map { ($0.path, $0.table) },
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
            deadBranchesEnabled: configuration.isEnabled(.deadBranch)
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
        unused.append(contentsOf: artifacts.deadBranches)

        let mapper = FindingMapper(configuration: configuration, mode: .simple)
        let findings = mapper.findings(from: unused, context: context)

        var report = AnalysisReport()
        report.analyzedFileCount = 1
        for note in artifacts.degraded {
            report.degradedFiles.append(.init(path: path, detail: note))
        }
        for finding in findings {
            if let reason = artifacts.table.suppression(for: finding.rule, line: finding.line) {
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
    /// corpus, the suppression table, per-function dead branches, and any
    /// degraded-analysis notes (e.g. an over-bound function the dead-branch
    /// pass skipped).
    private struct FileArtifacts: Sendable {
        let path: String
        let facts: FileAnalysisResult
        let table: SuppressionTable
        let deadBranches: [UnusedCode]
        let degraded: [String]
    }

    private static func collectArtifacts(
        path: String,
        source: String,
        deadBranchesEnabled: Bool
    ) -> FileArtifacts {
        // One SourceLocationConverter per file: the directive scanner, both
        // fact collectors, and the CFG builder all share this line table.
        let tree = foldedTree(Parser.parse(source: source))
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        let directives = DirectiveScanner.scan(tree: tree, converter: converter)
        let facts = StaticAnalyzer().collectFacts(tree: tree, file: path, converter: converter)
        let deadBranchOutput =
            deadBranchesEnabled
            ? DeadBranchPass.run(tree: tree, file: path, converter: converter)
            : DeadBranchPass.Output()
        return FileArtifacts(
            path: path,
            facts: facts,
            table: SuppressionTable(directives: directives),
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
            mode: mode,
            minimumConfidence: .low,
            treatPublicAsRoot: !wantsPublicApi,
            treatVisibleOutsideFileAsRoot: mode == .simple
        )
    }
}
