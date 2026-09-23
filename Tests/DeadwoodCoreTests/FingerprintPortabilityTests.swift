//  FingerprintPortabilityTests.swift
//  deadwood
//
//  A baseline is only useful if the same finding fingerprints identically
//  wherever it is computed. Before fingerprints were anchored to the
//  repository, a run with --relative-to and one without shared zero
//  fingerprints, so a baseline written locally suppressed nothing in CI —
//  silently, because a fingerprint matching nothing is indistinguishable from a
//  genuinely new finding.

import Foundation
import Testing

@testable import DeadwoodCore

@Suite struct FingerprintPortabilityTests {
    private func makeCheckout(named name: String) throws -> (root: URL, files: [String]) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deadwood-fp-\(name)-\(UUID().uuidString)")
        var completed = false
        defer {
            if !completed { try? FileManager.default.removeItem(at: root) }
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // A `.git` entry is what marks the anchor; its contents are irrelevant.
        try Data().write(to: root.appendingPathComponent(".git"))
        let file = root.appendingPathComponent("Sample.swift")
        try "private func unusedHelper() {}\nfinal class Widget {}\n".write(to: file, atomically: true, encoding: .utf8)
        completed = true
        return (root, [file.path])
    }

    @Test("The same code in two checkouts fingerprints identically")
    func portableAcrossCheckouts() async throws {
        let hereCheckout = try makeCheckout(named: "here")
        defer { try? FileManager.default.removeItem(at: hereCheckout.root) }
        let thereCheckout = try makeCheckout(named: "there")
        defer { try? FileManager.default.removeItem(at: thereCheckout.root) }
        let here = await Analyzer().analyze(files: hereCheckout.files)
        let there = await Analyzer().analyze(files: thereCheckout.files)
        #expect(!here.findings.isEmpty)
        #expect(here.findings.map(\.fingerprint) == there.findings.map(\.fingerprint))
        #expect(here.findings[0].path != there.findings[0].path)
    }

    @Test("Fingerprints hash the repository-relative path")
    func anchoredToRepositoryRoot() async throws {
        let checkout = try makeCheckout(named: "anchor")
        defer { try? FileManager.default.removeItem(at: checkout.root) }
        let report = await Analyzer().analyze(files: checkout.files)
        let finding = try #require(report.findings.first)
        #expect(finding.fingerprintPath == "Sample.swift")
    }
}
