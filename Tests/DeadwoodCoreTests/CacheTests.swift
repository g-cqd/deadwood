import Foundation
import Testing

@testable import DeadwoodCore

/// The fail-open facts cache: hits reuse per-file artifacts byte-for-byte,
/// misses re-parse, corruption and version drift behave as an empty cache,
/// and the persisted cache is rebuilt from only the current run's files.
@Suite struct CacheTests {
    private func makeWorkspace() throws -> (dir: URL, cache: URL, files: [String]) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "deadwood-cache-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let gated = """
            func gated() -> Int {
                if false { return 1 }
                return 0
            }
            @main struct M { static func main() { _ = gated() } }
            """
        let clean = """
            func helper() -> Int { gatedTwice() }
            func gatedTwice() -> Int { 2 }
            """
        let first = dir.appending(path: "Gated.swift")
        let second = dir.appending(path: "Helper.swift")
        try gated.write(to: first, atomically: true, encoding: .utf8)
        try clean.write(to: second, atomically: true, encoding: .utf8)
        let cache = dir.appending(path: "facts-cache.json")
        return (dir, cache, [first.path, second.path])
    }

    @Test func warmRunReusesFactsAndFindingsMatch() async throws {
        let (_, cache, files) = try makeWorkspace()

        let cold = await Analyzer().analyze(files: files, cacheURL: cache)
        #expect(cold.cacheHits == 0)
        #expect(cold.cacheMisses == 2)
        #expect(cold.findings.contains { $0.rule == .deadBranch })

        let warm = await Analyzer().analyze(files: files, cacheURL: cache)
        #expect(warm.cacheHits == 2)
        #expect(warm.cacheMisses == 0)
        #expect(warm.findings == cold.findings)
    }

    @Test func editedFileInvalidatesOnlyItsEntry() async throws {
        let (dir, cache, files) = try makeWorkspace()
        _ = await Analyzer().analyze(files: files, cacheURL: cache)

        let edited = dir.appending(path: "Helper.swift")
        try """
        func helper() -> Int {
            if false { return -1 }
            return gatedTwice()
        }
        func gatedTwice() -> Int { 2 }
        """.write(to: edited, atomically: true, encoding: .utf8)

        let rerun = await Analyzer().analyze(files: files, cacheURL: cache)
        #expect(rerun.cacheHits == 1)
        #expect(rerun.cacheMisses == 1)
        #expect(rerun.findings.filter { $0.rule == .deadBranch }.count == 2)
    }

    @Test func prunesEntriesForFilesAbsentThisRun() async throws {
        let (_, cache, files) = try makeWorkspace()
        _ = await Analyzer().analyze(files: files, cacheURL: cache)

        // Re-run on only the first file — the cache must no longer carry
        // the second file's entry (per-run rebuild, not append-forever).
        _ = await Analyzer().analyze(files: [files[0]], cacheURL: cache)
        let reloaded = FactsCache.load(url: cache)
        #expect(reloaded.entries.count == 1)
        #expect(reloaded.entries.keys.contains(files[0]))
    }

    @Test func corruptCacheFailsOpen() async throws {
        let (_, cache, files) = try makeWorkspace()
        try "not json at all {{{".write(to: cache, atomically: true, encoding: .utf8)

        let report = await Analyzer().analyze(files: files, cacheURL: cache)
        #expect(report.cacheHits == 0)
        #expect(report.cacheMisses == 2)
        #expect(report.findings.contains { $0.rule == .deadBranch })

        // And the bad file was overwritten with a valid cache.
        let warm = await Analyzer().analyze(files: files, cacheURL: cache)
        #expect(warm.cacheHits == 2)
    }

    @Test func toolVersionMismatchDiscardsCache() throws {
        var cache = FactsCache()
        cache.update(
            path: "/tmp/x.swift",
            fingerprint: "abc",
            artifacts: CachedFileArtifacts(
                facts: FileAnalysisResult(
                    file: "/tmp/x.swift", declarations: [], references: [], scopes: []),
                directives: [],
                deadBranches: [],
                degraded: []
            )
        )
        let url = FileManager.default.temporaryDirectory
            .appending(path: "deadwood-version-test-\(UUID().uuidString).json")
        cache.persist(url: url)

        var onDisk = try #require(
            String(data: Data(contentsOf: url), encoding: .utf8)
        )
        onDisk = onDisk.replacingOccurrences(of: ToolInfo.version, with: "0.0.0-other")
        try onDisk.write(to: url, atomically: true, encoding: .utf8)

        let reloaded = FactsCache.load(url: url)
        #expect(reloaded.entries.isEmpty)
    }

    @Test func ruleToggleSaltInvalidatesEntries() async throws {
        // Cached artifacts include dataflow findings, so flipping the
        // dead-store rule must miss the cache rather than serve stale facts.
        let (_, cache, files) = try makeWorkspace()
        _ = await Analyzer().analyze(files: files, cacheURL: cache)

        let deadStoresOn = Configuration(rules: ["dead-store": .init(enabled: true)])
        let rerun = await Analyzer(configuration: deadStoresOn)
            .analyze(files: files, cacheURL: cache)
        #expect(rerun.cacheHits == 0)
        #expect(rerun.cacheMisses == 2)
    }

    @Test func fingerprintIsStableAndLengthSuffixed() {
        let data = Data("let x = 1".utf8)
        let first = FactsCache.fingerprint(of: data)
        let second = FactsCache.fingerprint(of: data)
        #expect(first == second)
        #expect(first.hasSuffix("-\(data.count)"))
        #expect(FactsCache.fingerprint(of: data, salt: "other") != first)
    }
}
