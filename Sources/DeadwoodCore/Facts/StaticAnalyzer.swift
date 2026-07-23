//  Lifted from SwiftStaticAnalysis (MIT) — SwiftStaticAnalysisCore.swift.
//  Changes during the lift:
//  - The `@_exported import SwiftSyntax` re-export is gone; SwiftSyntax is
//    an implementation detail of this module.
//  - `SwiftFileParser` (actor + LRU cache) is replaced by direct
//    `Parser.parse(source:)`; file reading happens in the Analyzer through
//    `BoundedFileReader`, so parsing here is pure and synchronous.
//  - `AnalysisStatistics` bookkeeping dropped.

import SwiftParser
import SwiftSyntax

// MARK: - StaticAnalyzer

/// Collects declaration/reference/scope facts from Swift sources: the
/// shared substrate every detection pass consumes.
struct StaticAnalyzer: Sendable {
    /// Concurrency limits for the corpus fan-out.
    let concurrency: ConcurrencyConfiguration

    init(concurrency: ConcurrencyConfiguration = .default) {
        self.concurrency = concurrency
    }

    /// Collect facts from one file's already-parsed tree. The caller
    /// provides the file's one `SourceLocationConverter`; both collectors
    /// share it instead of rebuilding the line table.
    func collectFacts(
        tree: SourceFileSyntax,
        file: String,
        converter: SourceLocationConverter
    ) -> FileAnalysisResult {
        let declCollector = DeclarationCollector(file: file, converter: converter)
        declCollector.walk(tree)

        let refCollector = ReferenceCollector(file: file, converter: converter)
        refCollector.walk(tree)

        return FileAnalysisResult(
            file: file,
            declarations: declCollector.declarations + declCollector.imports,
            references: refCollector.references,
            scopes: Array(declCollector.tracker.tree.scopes.values),
            stringLiteralTokens: refCollector.stringLiteralTokens
        )
    }

    /// Collect facts from one source string (parses and folds it first).
    func collectFacts(source: String, file: String) -> FileAnalysisResult {
        let tree = foldedTree(Parser.parse(source: source))
        let converter = SourceLocationConverter(fileName: file, tree: tree)
        return collectFacts(tree: tree, file: file, converter: converter)
    }

    /// Parse and collect facts for a corpus of in-memory sources in
    /// parallel, then aggregate deterministically (input order).
    func analyze(sources: [(path: String, source: String)]) async -> AnalysisResult {
        let results = await ParallelProcessor.map(
            sources,
            maxConcurrency: concurrency.maxConcurrentFiles
        ) { entry in
            self.collectFacts(source: entry.source, file: entry.path)
        }
        return Self.aggregate(results, files: sources.map(\.path))
    }

    /// Merge per-file facts into one corpus-wide result.
    static func aggregate(_ results: [FileAnalysisResult], files: [String]) -> AnalysisResult {
        var declarationIndex = DeclarationIndex()
        var referenceIndex = ReferenceIndex()
        var scopeTree = ScopeTree()
        var stringTokens: Set<String> = []

        for result in results {
            for declaration in result.declarations {
                declarationIndex.add(declaration)
            }
            for reference in result.references {
                referenceIndex.add(reference)
            }
            for scope in result.scopes {
                scopeTree.add(scope)
            }
            stringTokens.formUnion(result.stringLiteralTokens)
        }

        return AnalysisResult(
            files: files,
            declarations: declarationIndex,
            references: referenceIndex,
            scopes: scopeTree,
            stringLiteralTokens: stringTokens
        )
    }
}
