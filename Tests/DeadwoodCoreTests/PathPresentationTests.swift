import DeadwoodCore
import Foundation
import Testing

/// Reported paths must not depend on where the repository sits on disk.
/// `Finding.fingerprint` hashes the path, so absolute paths make a baseline
/// written on a developer's machine match nothing in CI — and GitHub code
/// scanning resolves SARIF uris against the repository root, so absolute uris
/// link nowhere.
@Suite struct PathPresentationTests {
    private static let fixtureRoot = Bundle.module.resourceURL!
        .appending(path: "Fixtures/Findings")

    private func fixtureFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            at: Self.fixtureRoot, includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "swift" }
        .map(\.path)
        .sorted()
    }

    /// The directory the corpus sits in, taken from the corpus itself rather
    /// than from `Bundle.module` — the two can disagree on symlink spelling
    /// (/tmp vs /private/tmp), and this test is about relativization, not about
    /// how the bundle spells its own location.
    private func root(of corpus: [String]) -> String {
        URL(fileURLWithPath: corpus[0]).deletingLastPathComponent().path
    }

    @Test("Relativizing strips the root from paths, messages and notes")
    func pathsBecomeRelative() async throws {
        let corpus = try fixtureFiles()
        let report = await Analyzer().analyze(files: corpus)
            .relativized(to: root(of: corpus))
        #expect(!report.findings.isEmpty)
        for finding in report.findings {
            #expect(!finding.path.hasPrefix("/"), "still absolute: \(finding.path)")
            #expect(!finding.message.contains(root(of: corpus)))
            #expect(finding.note?.contains(root(of: corpus)) != true)
        }
    }

    @Test("The same code at a different location fingerprints identically")
    func fingerprintsSurviveRelocation() async throws {
        let corpus = try fixtureFiles()
        let relocated = FileManager.default.temporaryDirectory
            .appending(path: "relocated-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: relocated)
        try FileManager.default.copyItem(at: Self.fixtureRoot, to: relocated)
        defer { try? FileManager.default.removeItem(at: relocated) }

        let movedCorpus = corpus.map {
            relocated.appending(path: URL(fileURLWithPath: $0).lastPathComponent).path
        }

        let here = await Analyzer().analyze(files: corpus)
            .relativized(to: root(of: corpus))
        let there = await Analyzer().analyze(files: movedCorpus)
            .relativized(to: relocated.path)

        // This is the property a committed baseline depends on.
        #expect(here.findings.map(\.path) == there.findings.map(\.path))
        #expect(here.findings.map(\.fingerprint) == there.findings.map(\.fingerprint))
    }

    @Test("Paths outside the root are left absolute rather than escaped")
    func outsidePathsStayAbsolute() async throws {
        let corpus = try fixtureFiles()
        let report = await Analyzer().analyze(files: corpus)
            .relativized(to: "/definitely/not/the/fixture/root")
        #expect(report.findings.allSatisfy { $0.path.hasPrefix("/") })
        #expect(report.findings.allSatisfy { !$0.path.contains("..") })
    }
}
