import DeadwoodCore
import Foundation
import Testing

/// Report scoping narrows what a run *reports*, never what it analyzes. For
/// deadwood the distinction is not an optimization but a correctness
/// requirement: a declaration looks unused exactly when nothing references it,
/// so shrinking the corpus turns every cross-file reference into a false
/// positive.
@Suite struct ReportScopeTests {
    private static let fixtureRoot = Bundle.module.resourceURL!
        .appending(path: "Fixtures")

    private func files(in directory: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            at: Self.fixtureRoot.appending(path: directory), includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "swift" }
        .map(\.path)
        .sorted()
    }

    @Test("No scope reports everything and leaves outOfScope empty")
    func unscopedIsUnchanged() async throws {
        let report = await Analyzer().analyze(files: try files(in: "Findings"))
        #expect(!report.findings.isEmpty)
        #expect(report.outOfScope.isEmpty)
    }

    @Test("Scoping to one file reports only that file, corpus intact")
    func scopeToOneFile() async throws {
        let corpus = try files(in: "Findings")
        let unscoped = await Analyzer().analyze(files: corpus)
        let target = try #require(unscoped.findings.first).path
        let expected = unscoped.findings.filter { $0.path == target }

        let report = await Analyzer()
            .analyze(files: corpus, reportScope: ReportScope(files: [target]))
        #expect(report.findings.map(\.fingerprint) == expected.map(\.fingerprint))
        #expect(report.outOfScope.count == unscoped.findings.count - expected.count)
        // The whole corpus still drove reachability, which is the entire point.
        #expect(report.analyzedFileCount == unscoped.analyzedFileCount)
    }

    @Test("Scoping to the whole corpus is a no-op, fingerprints included")
    func fullScopeIsANoOp() async throws {
        let corpus = try files(in: "Findings")
        let unscoped = await Analyzer().analyze(files: corpus)

        let report = await Analyzer()
            .analyze(files: corpus, reportScope: ReportScope(files: corpus))
        // What lets a scoped CI run share a baseline with an unscoped one.
        #expect(report.findings.map(\.fingerprint) == unscoped.findings.map(\.fingerprint))
        #expect(report.outOfScope.isEmpty)
    }

    @Test("An empty scope reports nothing rather than everything")
    func emptyScopeIsNotAbsentScope() async throws {
        // `--only-from` pointed at a change set with no Swift files must report
        // nothing. Treating that as "no scope" would report the entire corpus
        // on exactly the pull requests that touched no code.
        let corpus = try files(in: "Findings")
        let report = await Analyzer()
            .analyze(files: corpus, reportScope: ReportScope(files: [] as [String]))
        #expect(report.findings.isEmpty)
        #expect(!report.outOfScope.isEmpty)
    }

    @Test("Scope entries are canonicalized, so relative paths match")
    func scopeAcceptsUncanonicalPaths() async throws {
        let corpus = try files(in: "Findings")
        let unscoped = await Analyzer().analyze(files: corpus)
        let target = try #require(unscoped.findings.first).path
        let awkward = URL(fileURLWithPath: target).deletingLastPathComponent()
            .appending(path: ".")
            .appending(path: URL(fileURLWithPath: target).lastPathComponent).path

        let report = await Analyzer()
            .analyze(files: corpus, reportScope: ReportScope(files: [awkward]))
        #expect(report.findings.allSatisfy { $0.path == target })
        #expect(!report.findings.isEmpty)
    }

    @Test("Scoping the report beats shrinking the corpus: no cross-file false positive")
    func scopingDoesNotInventDeadCode() async throws {
        // The regression that motivates report-scoping over input-scoping.
        // `Helper` is declared in A and used only from B. Feed the analyzer
        // just A — the shape a naive "analyze the changed files" gate takes —
        // and it correctly-but-uselessly reports Helper as unused. Feed it both
        // and scope the report to A, and it stays quiet.
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "deadwood-scope-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let a = directory.appending(path: "A.swift")
        let b = directory.appending(path: "B.swift")
        try "struct Helper { static func work() {} }\n"
            .write(to: a, atomically: true, encoding: .utf8)
        try "@main struct Entry {\n    static func main() { Helper.work() }\n}\n"
            .write(to: b, atomically: true, encoding: .utf8)

        let corpus = [a.path, b.path]
        let scoped = await Analyzer()
            .analyze(files: corpus, reportScope: ReportScope(files: [a.path]))
        let shrunkCorpus = await Analyzer().analyze(files: [a.path])

        #expect(
            !scoped.findings.contains { $0.message.contains("Helper") },
            "whole-corpus analysis sees B's reference: \(scoped.findings)")
        #expect(
            shrunkCorpus.findings.contains { $0.message.contains("Helper") },
            "a one-file corpus cannot see B, so it must over-report: \(shrunkCorpus.findings)")
    }
}
