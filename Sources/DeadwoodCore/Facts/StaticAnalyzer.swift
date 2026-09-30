//  Lifted from SwiftStaticAnalysis (MIT) — SwiftStaticAnalysisCore.swift.
//  Changes during the lift:
//  - The `@_exported import SwiftSyntax` re-export is gone; SwiftSyntax is
//    an implementation detail of this module.
//  - `SwiftFileParser` (actor + LRU cache) is replaced by direct
//    `Parser.parse(source:)`; file reading happens in the Analyzer through
//    `BoundedFileReader`, so parsing here is pure and synchronous.
//  - `AnalysisStatistics` bookkeeping dropped.

import ProjectModel
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
            declarations: declCollector.declarations + declCollector.imports
                + Self.topLevelCodeDeclarations(tree: tree, file: file, converter: converter),
            references: refCollector.references,
            scopes: Array(declCollector.tracker.tree.scopes.values),
            stringLiteralTokens: refCollector.stringLiteralTokens,
            isGenerated: GeneratedCode.isGenerated(path: file, tree: tree),
            regionSpans: CodeRegionScanner.scan(tree, converter: converter).map(CodeRegionSpan.init)
        )
    }

    /// One synthesized node per run of file-scope code (`#Preview`, script
    /// statements). Their line ranges hold the references made from that
    /// code, so reachability sees them; `RootDetector` roots them.
    static func topLevelCodeDeclarations(
        tree: SourceFileSyntax,
        file: String,
        converter: SourceLocationConverter
    ) -> [Declaration] {
        TopLevelCodeScanner.scan(tree, converter: converter).map { code in
            let start = SourceLocation(file: file, line: code.startLine, column: 1)
            let end = SourceLocation(file: file, line: code.endLine, column: 1)
            return Declaration(
                name: Self.topLevelCodeName(for: code),
                kind: .topLevelCode,
                accessLevel: .private,
                modifiers: [],
                location: start,
                range: SourceRange(start: start, end: end),
                scope: .global
            )
        }
    }

    private static func topLevelCodeName(for code: TopLevelCode) -> String {
        switch code.kind {
        case .preview: Declaration.previewCodeName
        case .macro: "#\(code.macroName)"
        case .statements: Declaration.topLevelStatementsName
        }
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
        var generatedFiles: Set<String> = []
        var regionSpansByFile: [String: [CodeRegionSpan]] = [:]

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
            if result.isGenerated {
                generatedFiles.insert(result.file)
            }
            if !result.regionSpans.isEmpty {
                regionSpansByFile[result.file] = result.regionSpans
            }
        }

        return AnalysisResult(
            files: files,
            declarations: declarationIndex,
            references: referenceIndex,
            scopes: scopeTree,
            stringLiteralTokens: stringTokens,
            generatedFiles: generatedFiles,
            regionSpansByFile: regionSpansByFile
        )
    }
}
