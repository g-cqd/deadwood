import Foundation
import Testing

@testable import DeadwoodCore

/// The fail-open facts cache: hits reuse the stored per-file facts,
/// misses re-parse, corruption and version drift behave as an empty cache,
/// and the persisted cache is rebuilt from only the current run's files.
@Suite struct CacheTests {
    private func makeWorkspace() throws -> (dir: URL, cache: URL, files: [String]) {
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
        let cache = dir.appending(path: "facts-cache.json")
        completed = true
        return (dir, cache, [first.path, second.path])
    }

    @Test func warmRunReusesFactsAndFindingsMatch() async throws {
        let (dir, cache, files) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cold = await Analyzer().analyze(files: files, cacheURL: cache)
        #expect(cold.cacheHits == 0)
        #expect(cold.cacheMisses == 2)
        #expect(cold.findings.contains { $0.rule == .deadBranch })
        let originalInode = try #require(
            FileManager.default.attributesOfItem(atPath: cache.path)[.systemFileNumber] as? NSNumber)

        let warm = await Analyzer().analyze(files: files, cacheURL: cache)
        #expect(warm.cacheHits == 2)
        #expect(warm.cacheMisses == 0)
        #expect(warm.findings == cold.findings)
        let warmInode = try #require(
            FileManager.default.attributesOfItem(atPath: cache.path)[.systemFileNumber] as? NSNumber)
        #expect(warmInode == originalInode)
    }

    @Test func editedFileInvalidatesOnlyItsEntry() async throws {
        let (dir, cache, files) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
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
        let (dir, cache, files) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = await Analyzer().analyze(files: files, cacheURL: cache)

        // Re-run on only the first file — the cache must no longer carry
        // the second file's entry (per-run rebuild, not append-forever).
        _ = await Analyzer().analyze(files: [files[0]], cacheURL: cache)
        let reloaded = FactsCache.load(url: cache)
        #expect(reloaded.entries.count == 1)
        #expect(reloaded.entries.keys.contains(files[0]))
    }

    @Test func corruptCacheFailsOpen() async throws {
        let (dir, cache, files) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
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
        defer { try? FileManager.default.removeItem(at: url) }
        cache.persist(url: url)

        let onDisk = try Data(contentsOf: url)
        let headerEnd = try #require(onDisk.firstIndex(of: UInt8(ascii: "\n")))
        let header = try #require(String(data: onDisk[...headerEnd], encoding: .utf8))
            .replacingOccurrences(of: ToolInfo.version, with: "0.0.0-other")
        var mismatched = Data(header.utf8)
        mismatched.append(onDisk.dropFirst(headerEnd + 1))
        try mismatched.write(to: url, options: .atomic)

        let reloaded = FactsCache.load(url: url)
        #expect(reloaded.entries.isEmpty)
    }

    @Test func ruleToggleSaltInvalidatesEntries() async throws {
        // Cached artifacts include dataflow findings, so flipping the
        // dead-store rule must miss the cache rather than serve stale facts.
        let (dir, cache, files) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = await Analyzer().analyze(files: files, cacheURL: cache)

        let deadStoresOn = Configuration(rules: ["dead-store": .init(enabled: true)])
        let rerun = await Analyzer(configuration: deadStoresOn)
            .analyze(files: files, cacheURL: cache)
        #expect(rerun.cacheHits == 0)
        #expect(rerun.cacheMisses == 2)
    }

    @Test("`Changing configuration invalidates cached entries`")
    func configurationChangeInvalidatesEntries() async throws {
        let (dir, cache, files) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = await Analyzer().analyze(files: files, cacheURL: cache)

        let changed = Configuration(testsGlob: "**/CustomTests/**")
        let rerun = await Analyzer(configuration: changed).analyze(files: files, cacheURL: cache)
        #expect(rerun.cacheHits == 0)
        #expect(rerun.cacheMisses == 2)
    }

    /// A cache hit is served before the file's bytes are validated as UTF-8.
    /// Builds that repaired invalid UTF-8 cached such files; their entries sit
    /// under the fingerprint salt of that time, so they must never match now.
    @Test func cacheFromBeforeUTF8ValidationCannotServeAnInvalidFile() async throws {
        let (dir, cache, files) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = await Analyzer().analyze(files: files, cacheURL: cache)

        let bad = dir.appending(path: "Bad.swift")
        let bytes = Data(Array("func broken() { _ = \"".utf8) + [0xFF] + Array("\" }\n".utf8))
        try bytes.write(to: bad)
        // What such a build cached for the file: artifacts under the fingerprint
        // it computed, salted as it salted them.
        var stale = FactsCache.load(url: cache)
        let artifacts = try #require(stale.entries[SourcePath.canonical(files[0])]?.artifacts)
        stale.update(
            path: SourcePath.canonical(bad.path),
            fingerprint: FactsCache.fingerprint(of: bytes, salt: "branches=true;stores=false"),
            artifacts: artifacts)
        stale.persist(url: cache)

        let report = await Analyzer().analyze(files: [bad.path], cacheURL: cache)
        #expect(report.cacheHits == 0)
        #expect(report.degradedFiles.map(\.detail) == ["not valid UTF-8"])
    }

    /// Round-trip structural equality on a REAL analyzed payload: persisting
    /// the cache, reloading it, and re-persisting must reproduce byte-identical
    /// output. That proves the stored fields round-trip deterministically
    /// across a decode without changing the cache's compact representation.
    @Test func realPayloadRoundTripsByteStable() async throws {
        let (dir, cache, files) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = await Analyzer().analyze(files: files, cacheURL: cache)

        let loaded = FactsCache.load(url: cache)
        #expect(loaded.entries.count == 2)

        let rePersist = dir.appending(path: "facts-cache-roundtrip.json")
        loaded.persist(url: rePersist)

        let first = try Data(contentsOf: cache)
        let second = try Data(contentsOf: rePersist)
        #expect(first == second)
        // A reload of the re-persisted file still yields the same entry set.
        #expect(FactsCache.load(url: rePersist).entries.count == 2)
    }

    @Test("`Persisted cache data never exceeds its read cap`")
    func persistedCacheNeverExceedsItsReadCap() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "deadwood-cap-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var cache = FactsCache()
        cache.update(
            path: "/x/Big.swift",
            fingerprint: "fp",
            artifacts: CachedFileArtifacts(
                facts: FileAnalysisResult(file: "/x/Big.swift", declarations: [], references: [], scopes: []),
                directives: [],
                deadBranches: [],
                degraded: [String(repeating: "x", count: FactsCache.maxCacheBytes)]
            )
        )

        let warning = cache.persist(url: url)
        #expect(warning?.contains("64 MiB") == true)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("`A corpus of references fits a compact cache without losing reachability inputs`")
    func referencesUseCompactCacheRepresentation() throws {
        let file = "/fixture/Sources/LongDirectoryName/Example.swift"
        let url = FileManager.default.temporaryDirectory
            .appending(path: "deadwood-compact-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
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
        var cache = FactsCache()
        cache.update(
            path: file,
            fingerprint: "fp",
            artifacts: CachedFileArtifacts(
                facts: FileAnalysisResult(file: file, declarations: [], references: references, scopes: []),
                directives: [], deadBranches: [], degraded: []
            )
        )
        cache.persist(url: url)

        let size = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        #expect(size < 80_000)
        let restored = try #require(FactsCache.load(url: url).artifacts(for: file, fingerprint: "fp"))
        #expect(restored.facts.references.count == references.count)
        #expect(restored.facts.references[0].qualifier == "Module")
        #expect(restored.facts.references[1].context == .write)
        #expect(restored.facts.references[999].location.line == 1_000)
        #expect(restored.facts.references.allSatisfy { $0.location.file == file })
    }

    @Test("`Malformed optional reference fields invalidate the cache`")
    func malformedReferenceQualifierIsACacheMiss() throws {
        let file = "/fixture/Example.swift"
        let url = FileManager.default.temporaryDirectory
            .appending(path: "deadwood-qualifier-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var cache = FactsCache()
        cache.update(
            path: file,
            fingerprint: "fp",
            artifacts: CachedFileArtifacts(
                facts: FileAnalysisResult(
                    file: file,
                    declarations: [],
                    references: [
                        Reference(
                            identifier: "name",
                            location: SourceLocation(file: file, line: 1, column: 1),
                            scope: .global,
                            context: .read,
                            qualifier: "Module")
                    ],
                    scopes: []),
                directives: [], deadBranches: [], degraded: [])
        )
        cache.persist(url: url)
        let valid = try #require(String(data: Data(contentsOf: url), encoding: .utf8))
        #expect(valid.contains("\"q\":\"Module\""))
        let invalid = valid.replacingOccurrences(of: "\"q\":\"Module\"", with: "\"q\":123")
        try invalid.write(to: url, atomically: true, encoding: .utf8)

        let loaded = FactsCache.load(url: url)
        #expect(loaded.entries.isEmpty)
        #expect(loaded.loadFailure != nil)
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
