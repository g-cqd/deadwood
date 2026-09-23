//  CancellationTests.swift
//  deadwood
//
//  A cancelled run must report nothing rather than something wrong:
//  deadwood decides \"unused\" by finding no reference anywhere, so a partial
///   corpus turns live declarations into false positives.
//  Under a CI timeout that is the difference between a failed job and a
//  confidently wrong one.

import Foundation
import Testing

@testable import DeadwoodCore

@Suite struct CancellationTests {
    private func makeWorkspace() throws -> (root: URL, files: [String]) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deadwood-cancel-\(UUID().uuidString)")
        var completed = false
        defer {
            if !completed { try? FileManager.default.removeItem(at: root) }
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var files: [String] = []
        for index in 0..<3 {
            let file = root.appendingPathComponent("File\(index).swift")
            try "private func unused\(index)() {}\nfinal class C\(index) {}\n"
                .write(to: file, atomically: true, encoding: .utf8)
            files.append(file.path)
        }
        completed = true
        return (root, files)
    }

    @Test("A cancelled run reports nothing and says so")
    func cancelledRunReportsNothing() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let task = Task { await Analyzer().analyze(files: workspace.files) }
        task.cancel()
        let report = await task.value
        #expect(report.wasCancelled)
        #expect(report.findings.isEmpty)
        #expect(report.outOfScope.isEmpty)
    }

    @Test("An uncancelled run over the same corpus is unaffected")
    func uncancelledRunIsNormal() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let report = await Analyzer().analyze(files: workspace.files)
        #expect(!report.wasCancelled)
    }
}
