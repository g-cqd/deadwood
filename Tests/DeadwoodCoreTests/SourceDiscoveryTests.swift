import Foundation
import Testing

@testable import DeadwoodCore

/// The walk behind `deadwood analyze <directory>`. A symlinked subtree is
/// analyzed like any other, but no link may send the walk round a loop or out
/// of the directory it was given: two links back to an ancestor used to make
/// it exponential, and a link out of the repository pulled another
/// repository's files into the corpus.
@Suite struct SourceDiscoveryTests {
    /// A scratch directory holding `root/A.swift` and `root/Sources/B.swift`,
    /// plus an `outside/Shared.swift` beside the root. The caller removes it.
    private func makeScratch() throws -> (scratch: URL, root: URL) {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "deadwood-walk-\(UUID().uuidString)")
        let root = scratch.appending(path: "root")
        var completed = false
        defer {
            if !completed { try? FileManager.default.removeItem(at: scratch) }
        }
        try write("A.swift", in: root)
        try write("Sources/B.swift", in: root)
        try write("outside/Shared.swift", in: scratch)
        completed = true
        return (scratch, root)
    }

    private func write(_ path: String, in directory: URL, contents: String = "let value = 1\n") throws {
        let file = directory.appending(path: path)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }

    private func link(_ path: String, to destination: String, in directory: URL) throws {
        try FileManager.default.createSymbolicLink(
            atPath: directory.appending(path: path).path, withDestinationPath: destination)
    }

    /// The files a walk of `root` must list when no link adds anything.
    private func realFiles(under root: URL) -> [String] {
        [root.path + "/A.swift", root.path + "/Sources/B.swift"]
    }

    @Test("A link back to an ancestor does not walk the tree again")
    func ancestorLinkIsNotReentered() throws {
        let (scratch, root) = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try link("Sources/Loop", to: "..", in: root)

        #expect(SourceDiscovery.swiftFiles(in: root.path) == realFiles(under: root))
    }

    @Test("Two links back to an ancestor finish and list each file once")
    func twoAncestorLinksFinish() throws {
        let (scratch, root) = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try link("Sources/Loop1", to: "..", in: root)
        try link("Sources/Loop2", to: "..", in: root)

        #expect(SourceDiscovery.swiftFiles(in: root.path) == realFiles(under: root))
    }

    @Test(
        "A link out of the root is not followed",
        arguments: [
            ("Shared", "../outside"),
            ("Linked.swift", "../outside/Shared.swift"),
            ("FileSystem", "/"),
        ])
    func outsideLinkIsNotFollowed(name: String, destination: String) throws {
        let (scratch, root) = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try link(name, to: destination, in: root)

        #expect(SourceDiscovery.swiftFiles(in: root.path) == realFiles(under: root))
    }

    @Test("A link inside the root is followed, and its files are listed once")
    func insideLinkIsFollowedOnce() throws {
        let (scratch, root) = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try link("Alias", to: "Sources", in: root)

        let files = SourceDiscovery.swiftFiles(in: root.path)
        #expect(files.count == 2)
        #expect(Set(SourcePath.canonicalized(files)) == Set(SourcePath.canonicalized(realFiles(under: root))))
    }

    @Test("A root named through a link keeps its spelling and its containment")
    func linkedRootIsContained() throws {
        let (scratch, root) = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try link("Sources/Loop", to: "..", in: root)
        try link("Linked", to: "root", in: scratch)
        let linked = scratch.appending(path: "Linked")

        #expect(SourceDiscovery.swiftFiles(in: linked.path) == realFiles(under: linked))
    }

    @Test("A dangling link stays listed, so the analyzer reports it degraded", arguments: [false, true])
    func danglingLinkIsListed(rootThroughLink: Bool) throws {
        let (scratch, root) = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try link("Sources/Broken.swift", to: "Missing.swift", in: root)
        try link("Linked", to: "root", in: scratch)
        let walked = rootThroughLink ? scratch.appending(path: "Linked") : root

        #expect(
            SourceDiscovery.swiftFiles(in: walked.path)
                == realFiles(under: walked) + [walked.path + "/Sources/Broken.swift"])
    }

    @Test("Hidden entries and build products are skipped")
    func skippedEntries() throws {
        let (scratch, root) = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        for skipped in [".hidden", ".build", "DerivedData", ".swiftpm", "checkouts"] {
            try write("\(skipped)/X.swift", in: root)
        }
        try write("Sources/Notes.md", in: root)

        #expect(SourceDiscovery.swiftFiles(in: root.path) == realFiles(under: root))
    }

    /// The shared-sources setup: a directory in the repository linked into a
    /// sibling checkout. Following the link put two repositories in one corpus,
    /// which leaves no repository to anchor fingerprints to, so every
    /// fingerprint fell back to its absolute path and a committed baseline
    /// matched nothing on another machine.
    @Test("A link into a sibling repository leaves fingerprints anchored to the repository")
    func siblingRepositoryLinkKeepsFingerprintsAnchored() async throws {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "deadwood-walk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let repository = scratch.appending(path: "repository")
        let sibling = scratch.appending(path: "sibling")
        try write("Sources/Widget.swift", in: repository, contents: "private func unusedHelper() {}\n")
        try write("Sources/Shared.swift", in: sibling, contents: "private func sharedHelper() {}\n")
        // A `.git` entry is what marks a repository; its contents are irrelevant.
        for checkout in [repository, sibling] {
            try Data().write(to: checkout.appending(path: ".git"))
        }
        try link("Shared", to: "../sibling/Sources", in: repository)

        let report = await Analyzer().analyze(files: SourceDiscovery.swiftFiles(in: repository.path))
        #expect(report.analyzedFileCount == 1)
        let finding = try #require(report.findings.first)
        #expect(finding.fingerprintPath == "Sources/Widget.swift")
    }
}
