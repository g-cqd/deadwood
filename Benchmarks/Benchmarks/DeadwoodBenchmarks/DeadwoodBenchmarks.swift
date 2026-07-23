import Benchmark
@_spi(Benchmarks) import DeadwoodCore
import Foundation

// MARK: - Deterministic synthetic corpus

/// ~200-file corpus generated purely from index math (no randomness): types
/// with members, cross-file references (each service calls the next file's
/// service), deliberately dead declarations, and functions with branches
/// including one provably dead branch per file.
private func syntheticCorpus(fileCount: Int = 200) -> [(path: String, source: String)] {
    (0..<fileCount).map { index in
        let next = (index + 1) % fileCount
        var source = """
            struct Model\(index) {
                var id: Int = \(index)
                var name: String = "model\(index)"
                var score: Double = 0

                func describe() -> String { "\\(name):\\(id)" }

                func rescored(by factor: Double) -> Model\(index) {
                    var copy = self
                    copy.score += factor
                    return copy
                }
            }

            final class Service\(index) {
                let model = Model\(index)()
                private var counter = 0

                func run() {
                    counter += 1
                    _ = model.describe()
                    _ = model.rescored(by: Double(counter))
                    _ = process\(index)(counter)
                    _ = Route\(index)(rawValue: "home\(index)")
                    if counter < 1 { Service\(next)().run() }
                }
            }

            func process\(index)(_ n: Int) -> Int {
                let limit = 10
                var total = n
                if total > limit {
                    total += limit
                } else {
                    total -= 1
                }
                let verbose = false
                if verbose {
                    total = -total
                }
                var step = 0
                while step < 4 {
                    total += step
                    step += 1
                }
                switch total % 3 {
                case 0: total += 1
                case 1: total += 2
                default: total += 3
                }
                return total
            }

            enum Route\(index): String {
                case home = "home\(index)"
                case detail = "detail\(index)"
            }

            private func orphanHelper\(index)(_ value: Int) -> Int { value * 3 }

            private struct DeadConfig\(index) {
                let retries = 3
                func window() -> Int { retries * 2 }
            }

            """
        if index == 0 {
            source += """

                @main struct BenchmarkMain {
                    static func main() { Service0().run() }
                }

                """
        }
        return ("Corpus\(index).swift", source)
    }
}

/// Writes the corpus into a fixed temporary directory (content is
/// deterministic, so overwriting is idempotent) and returns absolute paths.
private func materializeCorpus(_ corpus: [(path: String, source: String)]) -> [String] {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "deadwood-benchmark-corpus")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return corpus.map { entry in
        let url = root.appending(path: entry.path)
        try? entry.source.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }
}

// MARK: - Benchmarks

let benchmarks: @Sendable () -> Void = {
    let corpus = syntheticCorpus()
    let paths = materializeCorpus(corpus)
    let facts = BenchmarkStages.prepareFacts(sources: corpus)

    let defaultMetrics: [BenchmarkMetric] = [.wallClock, .mallocCountTotal]

    Benchmark(
        "analyze end-to-end 200 files",
        configuration: .init(metrics: defaultMetrics, maxDuration: .seconds(10), maxIterations: 20)
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(await Analyzer().analyze(files: paths))
        }
    }

    // Warm facts cache: one cold run primes it; every measured iteration
    // reuses all 200 per-file artifacts (and re-persists the cache, as a
    // real warm run would).
    let cacheURL = FileManager.default.temporaryDirectory
        .appending(path: "deadwood-benchmark-cache/facts.json")

    Benchmark(
        "analyze end-to-end warm cache 200 files",
        configuration: .init(
            metrics: defaultMetrics,
            maxDuration: .seconds(10),
            maxIterations: 20,
            setup: {
                try? FileManager.default.removeItem(at: cacheURL)
                _ = await Analyzer().analyze(files: paths, cacheURL: cacheURL)
            }
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(await Analyzer().analyze(files: paths, cacheURL: cacheURL))
        }
    }

    Benchmark(
        "extraction stage (parse+collect) 200 files",
        configuration: .init(metrics: defaultMetrics, maxDuration: .seconds(10), maxIterations: 30)
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(BenchmarkStages.extractFacts(sources: corpus))
        }
    }

    Benchmark(
        "graph build + BFS 200 files",
        configuration: .init(metrics: defaultMetrics, maxDuration: .seconds(10), maxIterations: 30)
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(await BenchmarkStages.graphAndReachability(facts))
        }
    }

    Benchmark(
        "dead-branch stage 200 files",
        configuration: .init(metrics: defaultMetrics, maxDuration: .seconds(10), maxIterations: 30)
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(BenchmarkStages.deadBranchStage(sources: corpus))
        }
    }
}
