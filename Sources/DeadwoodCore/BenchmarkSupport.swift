//  Benchmark-only stage entry points for the local `Benchmarks/` package.
//  Hidden behind `@_spi(Benchmarks)`: not supported public API, exists so the
//  benchmark harness can time individual pipeline stages (extraction, graph
//  build + BFS, dead branches) without duplicating pipeline internals.

import SwiftParser
import SwiftSyntax

// MARK: - BenchmarkFacts

/// Opaque aggregated corpus facts, prepared once in benchmark setup so the
/// graph stage measures graph build + BFS only.
@_spi(Benchmarks)
public struct BenchmarkFacts: Sendable {
    let result: AnalysisResult
    let context: CorpusContext
}

// MARK: - BenchmarkStages

/// Per-stage entry points mirroring what the Analyzer pipeline runs per file.
/// Every function returns an opaque count so callers can black-hole a value
/// derived from the full computation.
@_spi(Benchmarks)
public enum BenchmarkStages {
    /// Extraction stage: parse + fold + collect declaration/reference/scope
    /// facts for every source.
    public static func extractFacts(sources: [(path: String, source: String)]) -> Int {
        var total = 0
        for entry in sources {
            let facts = StaticAnalyzer().collectFacts(source: entry.source, file: entry.path)
            total += facts.declarations.count + facts.references.count
        }
        return total
    }

    /// Aggregate corpus facts (benchmark setup for the graph stage; not the
    /// timed region).
    public static func prepareFacts(sources: [(path: String, source: String)]) -> BenchmarkFacts {
        let perFile = sources.map { entry in
            StaticAnalyzer().collectFacts(source: entry.source, file: entry.path)
        }
        let result = StaticAnalyzer.aggregate(perFile, files: sources.map(\.path))
        return BenchmarkFacts(result: result, context: CorpusContext(result: result))
    }

    /// Graph stage: root detection + dependency edges + reachability BFS.
    public static func graphAndReachability(_ facts: BenchmarkFacts) async -> Int {
        let extractor = DependencyExtractor()
        let graph = await extractor.buildGraph(from: facts.result, context: facts.context)
        return await graph.computeUnreachable().count
    }

    /// Dead-branch stage: parse + CFG construction + SCCP over every
    /// function body of every source.
    public static func deadBranchStage(sources: [(path: String, source: String)]) -> Int {
        var total = 0
        for entry in sources {
            let tree = foldedTree(Parser.parse(source: entry.source))
            let converter = SourceLocationConverter(fileName: entry.path, tree: tree)
            total +=
                DeadBranchPass.run(tree: tree, file: entry.path, converter: converter)
                .findings.count
        }
        return total
    }
}
