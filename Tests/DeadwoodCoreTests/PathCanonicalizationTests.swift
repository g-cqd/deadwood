import DeadwoodCore
import Foundation
import Testing

/// `Finding.path` is hashed into `Finding.fingerprint`, which `--baseline`
/// matches on. So the corpus must be identified by *file*, never by the string
/// the caller happened to use: CI passes an explicit changed-file list while
/// baselines are written from a directory walk, and those two must agree.
@Suite struct PathCanonicalizationTests {
    private static let findingsRoot = Bundle.module.resourceURL!
        .appending(path: "Fixtures/Findings")

    private func fixtureFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            at: Self.findingsRoot, includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "swift" }
        .map(\.path)
        .sorted()
    }

    /// The same file reached through a redundant `.` and a `..` round-trip —
    /// what a naive changed-file list or a relative CI path produces.
    private func awkward(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent()
        return parent.appending(path: ".").appending(path: "..")
            .appending(path: parent.lastPathComponent)
            .appending(path: url.lastPathComponent).path
    }

    @Test("Spelling the corpus differently does not move a single fingerprint")
    func spellingDoesNotAffectFingerprints() async throws {
        let canonical = try fixtureFiles()
        let scenicPaths = canonical.map(awkward)
        #expect(scenicPaths != canonical, "the awkward spelling must actually differ")

        let plain = await Analyzer().analyze(files: canonical)
        let scenic = await Analyzer().analyze(files: scenicPaths)

        #expect(!plain.findings.isEmpty, "fixtures must produce findings to compare")
        #expect(plain.findings.map(\.path) == scenic.findings.map(\.path))
        #expect(plain.findings.map(\.fingerprint) == scenic.findings.map(\.fingerprint))

        // The property that actually matters downstream: a baseline written
        // from one spelling suppresses every finding produced by the other.
        #expect(Baseline(findings: plain.findings).filter(scenic.findings).kept.isEmpty)
    }

    @Test("The same file named twice is one corpus entry")
    func duplicateSpellingsCollapse() async throws {
        let file = try #require(try fixtureFiles().first)

        let once = await Analyzer().analyze(files: [file])
        let twice = await Analyzer().analyze(files: [file, awkward(file)])

        // A duplicate entry used to double-count the file's declarations in the
        // reachability graph and inflate the "in N file(s)" summary.
        #expect(twice.analyzedFileCount == 1)
        #expect(twice.findings.map(\.fingerprint) == once.findings.map(\.fingerprint))
    }
}
