import Foundation
import Testing

/// deadwood's `analyze` on analyzerkit's shared option groups (ADR-0019, roadmap 0019): Input, Output, Rules, Cache,
/// Index and Experimental, with the old spellings kept as aliases, its cache on `CorpusScanner`, and regions from the
/// project.
@Suite(.serialized) struct CommandLineSurfaceTests {
    /// A private function of a public type nothing calls: one `unused-function` warning.
    private static func unused(_ name: String) -> String {
        "public enum \(name) {\n    public static func run() {}\n    private static func unused\(name)() {}\n}\n"
    }

    private struct Run {
        let status: Int32
        let output: String
        let errors: String
    }

    private static func run(_ arguments: [String], in root: URL) throws -> Run {
        let run = try BuiltTool.run(arguments, in: root)
        return Run(
            status: run.status, output: String(decoding: run.standardOutput, as: UTF8.self),
            errors: run.standardError)
    }

    private static func workspace(_ files: [String: String], _ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "deadwood-cli-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("gitdir: none\n".utf8).write(to: root.appending(path: ".git"))
        for (name, text) in files {
            let url = root.appending(path: name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try body(root)
    }

    @Test func `the help lists every shared option and deadwood's own after them`() throws {
        try Self.workspace([:]) { root in
            let run = try Self.run(["analyze", "--help"], in: root)
            for option in [
                "--config", "--exclude-path", "--include-regions", "--exclude-regions", "--define", "--only",
                "--only-from", "--format", "--relative-to", "--strict", "--baseline", "--write-baseline",
                "--report-new-since", "--verbose", "--quiet", "--timings", "--rules", "--cache-path", "--no-cache",
                "--index-store", "--index-store-path", "--index-store-build", "--experimental-embeddings",
                "--embedding-bundle", "--production", "--minimum-confidence",
            ] {
                #expect(run.output.contains(option), "missing \(option)")
            }
        }
    }

    @Test func `the old region and embedding spellings still work, with a note`() throws {
        try Self.workspace(["A.swift": Self.unused("A")]) { root in
            let run = try Self.run(
                [
                    "analyze", ".", "--no-cache", "--include", "test", "--exclude", "mock",
                    "--experimental-embedding-confidence",
                ], in: root)
            #expect(run.errors.contains("deadwood: note: --include is deprecated; use --include-regions"))
            #expect(run.errors.contains("deadwood: note: --exclude is deprecated; use --exclude-regions"))
            #expect(
                run.errors.contains(
                    "deadwood: note: --experimental-embedding-confidence is deprecated; use --experimental-embeddings confidence"
                ))
            #expect(run.output.contains("unusedA"))
        }
    }

    @Test func `define has no effect, and says so`() throws {
        try Self.workspace(["A.swift": Self.unused("A")]) { root in
            let run = try Self.run(["analyze", ".", "--no-cache", "--define", "DEBUG"], in: root)
            #expect(run.errors.contains("deadwood: note: --define has no effect"))
        }
    }

    /// Like the configuration's `exclude`, `--exclude-path` scopes the report, never the corpus: the excluded file's
    /// references still count.
    @Test func `exclude-path leaves a file out of the report, not out of the corpus`() throws {
        try Self.workspace([
            "A.swift": Self.unused("A"), "B.swift": Self.unused("B"),
            "Lib.swift": "func helper() {}\n", "main.swift": "helper()\n",
        ]) { root in
            let run = try Self.run(
                ["analyze", ".", "--no-cache", "--exclude-path", "B.swift", "--exclude-path", "main.swift"], in: root)
            #expect(run.output.contains("unusedA") && !run.output.contains("unusedB"), "\(run.output)")
            #expect(!run.output.contains("helper"), "\(run.output)")
        }
    }

    @Test func `rules chooses the rules that run, and an unknown one is a usage error`() throws {
        try Self.workspace(["A.swift": Self.unused("A")]) { root in
            let other = try Self.run(["analyze", ".", "--no-cache", "--rules", "dead-branch"], in: root)
            #expect(other.status == 0 && other.output.isEmpty, "\(other.output)")
            let same = try Self.run(["analyze", ".", "--no-cache", "--rules", "unused-function"], in: root)
            #expect(same.output.contains("unused-function"))
            let unknown = try Self.run(["analyze", ".", "--no-cache", "--rules", "nope"], in: root)
            #expect(unknown.status == 64)
        }
    }

    @Test func `quiet, verbose and timings`() throws {
        try Self.workspace(["A.swift": Self.unused("A")]) { root in
            let quiet = try Self.run(["analyze", ".", "--no-cache", "--quiet"], in: root)
            #expect(quiet.errors.isEmpty, "\(quiet.errors)")
            let verbose = try Self.run(["analyze", ".", "--no-cache", "--verbose"], in: root)
            #expect(verbose.errors.contains("deadwood: configuration:"), "\(verbose.errors)")
            let timed = try Self.run(["analyze", ".", "--no-cache", "--format", "json", "--timings"], in: root)
            #expect(timed.output.contains("\"timings\""))
        }
    }

    /// `--cache-path` names the cache's root directory (ADR-0011); a second run reuses every file.
    @Test func `a cache under cache-path is a directory and is reused`() throws {
        try Self.workspace(["A.swift": Self.unused("A"), "B.swift": "let b = 1\n"]) { root in
            let cache = root.appending(path: "cache").path
            _ = try Self.run(["analyze", ".", "--cache-path", cache], in: root)
            let type = (try? FileManager.default.attributesOfItem(atPath: cache))?[.type] as? FileAttributeType
            #expect(type == .typeDirectory)
            let warm = try Self.run(["analyze", ".", "--cache-path", cache, "--format", "json"], in: root)
            #expect(warm.output.contains(#""cacheHits" : 2"#), "\(warm.output)")
        }
    }

    /// In production mode, code a test target outside `Tests/` declares is test code: what only it uses is
    /// `referenced-only-by-tests`, though its public function would otherwise be a production root.
    @Test func `a test target outside Tests is test code`() throws {
        let manifest = """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(name: "P", targets: [
                .target(name: "Lib", path: "Lib"), .testTarget(name: "Checks", dependencies: ["Lib"], path: "Checks"),
            ])
            """
        try Self.workspace([
            "Package.swift": manifest, "Lib/L.swift": "func helper() {}\n",
            "Checks/C.swift": "public func checkAll() { helper() }\n",
        ]) { root in
            let run = try Self.run(["analyze", ".", "--no-cache", "--production"], in: root)
            #expect(run.output.contains("referenced-only-by-tests"), "\(run.output)")
        }
    }
}
