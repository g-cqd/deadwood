import AemiProtobuf
import AemiProtobufCore
import CorpusScan
import Foundation
import SourceCorpus
import Testing

@testable import DeadwoodCore

/// The facts cache is an optimization and must never change results: hit and miss runs give identical findings. The
/// cache itself (shards, corruption failing open, the build identity, pruning, the budget) is analyzerkit's
/// `CorpusScanner`, tested there (roadmap 0019); what stays here is what deadwood keys and stores.
@Suite struct CacheTests {
    private func makeWorkspace() throws -> (dir: URL, cache: CacheLocation, files: [String]) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "deadwood-cache-test-\(UUID().uuidString)")
        var completed = false
        defer {
            if !completed { try? FileManager.default.removeItem(at: dir) }
        }
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
        let cache = CacheLocation(root: dir.appending(path: "cache").path, workspace: dir.path)
        completed = true
        return (dir, cache, [first.path, second.path])
    }

    @Test func warmRunReusesFactsAndFindingsMatch() async throws {
        let (dir, cache, files) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cold = await Analyzer().analyze(files: files, cache: cache)
        #expect(cold.cacheHits == 0)
        #expect(cold.cacheMisses == 2)
        #expect(cold.findings.contains { $0.rule == .deadBranch })

        let warm = await Analyzer().analyze(files: files, cache: cache)
        #expect(warm.cacheHits == 2)
        #expect(warm.cacheMisses == 0)
        #expect(warm.findings == cold.findings)
    }

    @Test func editedFileInvalidatesOnlyItsEntry() async throws {
        let (dir, cache, files) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = await Analyzer().analyze(files: files, cache: cache)

        try """
        func helper() -> Int {
            if false { return 3 }
            return gatedTwice()
        }
        func gatedTwice() -> Int { 2 }
        """.write(toFile: files[1], atomically: true, encoding: .utf8)

        let rerun = await Analyzer().analyze(files: files, cache: cache)
        #expect(rerun.cacheHits == 1)
        #expect(rerun.cacheMisses == 1)
    }

    @Test func ruleToggleSaltInvalidatesEntries() async throws {
        // Cached artifacts include dataflow findings, so flipping the
        // dead-store rule must miss the cache rather than serve stale facts.
        let (dir, cache, files) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = await Analyzer().analyze(files: files, cache: cache)

        let deadStoresOn = Configuration(rules: ["dead-store": .init(enabled: true)])
        let rerun = await Analyzer(configuration: deadStoresOn).analyze(files: files, cache: cache)
        #expect(rerun.cacheHits == 0)
        #expect(rerun.cacheMisses == 2)
    }

    @Test("`Changing configuration invalidates cached entries`")
    func configurationChangeInvalidatesEntries() async throws {
        let (dir, cache, files) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = await Analyzer().analyze(files: files, cache: cache)

        let changed = Configuration(testsGlob: "**/CustomTests/**")
        let rerun = await Analyzer(configuration: changed).analyze(files: files, cache: cache)
        #expect(rerun.cacheHits == 0)
        #expect(rerun.cacheMisses == 2)
    }

    /// A file that is not UTF-8 is cached as skipped, and reported the same on a warm run.
    @Test func invalidFileIsSkippedFromTheCacheToo() async throws {
        let (dir, cache, _) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bad = dir.appending(path: "Bad.swift")
        try Data(Array("func broken() { _ = \"".utf8) + [0xFF] + Array("\" }\n".utf8)).write(to: bad)
        for _ in 0..<2 {
            let report = await Analyzer().analyze(files: [bad.path], cache: cache)
            #expect(report.degradedFiles.map(\.detail) == ["not valid UTF-8"])
            #expect(report.findings.isEmpty)
        }
    }

    @Test func noCacheMeansNoCacheAccounting() async throws {
        let (dir, _, files) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = await Analyzer().analyze(files: files)
        #expect(report.cacheHits == 0)
        #expect(report.cacheMisses == 0)
    }

    /// The payload as the cache stores it: protobuf (analyzerkit roadmap 0017).
    private static func payload(_ artifacts: CachedFileArtifacts) throws -> [UInt8] {
        try ProtobufEncoder().encodeToBytes(ExtractedArtifacts(artifacts: artifacts))
    }

    private static func decoded(_ bytes: [UInt8]) throws -> ExtractedArtifacts {
        try ProtobufDecoder().decode(ExtractedArtifacts.self, fromBytes: bytes)
    }

    @Test("`A corpus of references fits a compact cache without losing reachability inputs`")
    func referencesUseCompactCacheRepresentation() throws {
        let file = "/fixture/Sources/LongDirectoryName/Example.swift"
        let references = (0..<1_000).map { index in
            Reference(
                identifier: "name\(index % 20)",
                location: SourceLocation(file: file, line: index + 1, column: 2, offset: index * 4),
                scope: ScopeID("scope"),
                context: index.isMultiple(of: 2) ? .read : .write,
                isQualified: index == 0,
                qualifier: index == 0 ? "Module" : nil
            )
        }
        let bytes = try Self.payload(
            CachedFileArtifacts(
                facts: FileAnalysisResult(file: file, declarations: [], references: references, scopes: []),
                directives: [], deadBranches: [], degraded: []))
        #expect(bytes.count < 80_000)

        let restored = try #require(
            try Self.decoded(bytes).artifacts)
        #expect(restored.facts.references.count == references.count)
        #expect(restored.facts.references[0].qualifier == "Module")
        #expect(restored.facts.references[1].context == .write)
        #expect(restored.facts.references[999].location.line == 1_000)
        #expect(restored.facts.references.allSatisfy { $0.location.file == file })
        #expect(try Self.payload(restored) == bytes, "byte-stable across a decode")
    }

    /// The content region is cached; the project's part is not.
    @Test func contentRegionRoundTrips() throws {
        let facts = FileAnalysisResult(
            file: "/x/G.swift", declarations: [], references: [], scopes: [], isGenerated: true, isTestCode: true)
        let bytes = try Self.payload(
            CachedFileArtifacts(facts: facts, directives: [], deadBranches: [], degraded: []))
        let restored = try #require(
            try Self.decoded(bytes).artifacts)
        #expect(restored.facts.contentRegion == facts.contentRegion)
        #expect(restored.facts.isGenerated && restored.facts.isTestCode)
    }

    /// A reference context this build does not know fails the payload, so the file is a miss and extracted again.
    @Test("`An unknown reference context fails to decode`")
    func unknownReferenceContextIsACacheMiss() throws {
        let file = "/fixture/Example.swift"
        let bytes = try Self.payload(
            CachedFileArtifacts(
                facts: FileAnalysisResult(
                    file: file, declarations: [],
                    references: [
                        Reference(
                            identifier: "name", location: SourceLocation(file: file, line: 1, column: 1),
                            scope: .global, context: .read, qualifier: "Module")
                    ],
                    scopes: []),
                directives: [], deadBranches: [], degraded: []))
        #expect(try Self.decoded(bytes).artifacts?.facts.references.first?.qualifier == "Module")
        let read = Array(ReferenceContext.read.rawValue.utf8)
        let corrupt = bytes.replacing(read, with: Array("nope".utf8.prefix(read.count)))
        #expect(corrupt != bytes)
        #expect(throws: (any Error).self) { try Self.decoded(corrupt) }
    }
}
