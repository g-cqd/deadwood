import DeadwoodCore
import Foundation
import Testing

@Suite struct PipelineTests {
    @Test func cleanSourceProducesNoFindings() {
        let report = Analyzer().analyze(source: "let x = 1\n", path: "t.swift")
        #expect(report.findings.isEmpty)
        #expect(report.analyzedFileCount == 1)
    }

    @Test func unknownConfigRuleFailsClosed() throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "deadwood-cfg-\(UUID().uuidString).json").path
        try #"{"rules": {"no-such-rule": {}}, "exclude": []}"#
            .write(toFile: path, atomically: true, encoding: .utf8)
        #expect(throws: DeadwoodError.self) {
            try Configuration.load(path: path)
        }
    }

    @Test func oversizedFileDegradesNotCrashes() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "deadwood-big-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let big = dir.appending(path: "Big.swift")
        #expect(FileManager.default.createFile(atPath: big.path, contents: nil))
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(Analyzer.sourceByteCap) + 1)
        try handle.close()

        let report = await Analyzer().analyze(files: [big.path])
        #expect(report.degradedFiles.count == 1)
    }

    /// Replacing invalid bytes analyzed text that is not in the file, and a
    /// file that was all replacement characters still counted as analyzed.
    @Test func invalidUTF8IsSkippedInsteadOfBeingRepaired() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "deadwood-utf8-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bad = dir.appending(path: "Bad.swift")
        try Data(Array("private func broken() { _ = \"".utf8) + [0xFF, 0xFE] + Array("\" }\n".utf8)).write(to: bad)
        let good = dir.appending(path: "Good.swift")
        try Data("let value = 1\n".utf8).write(to: good)

        // Cold, then warm: a cached run must not analyze the file either.
        let cache = dir.appending(path: "facts.json")
        for _ in 0..<2 {
            let report = await Analyzer().analyze(files: [bad.path, good.path], cacheURL: cache)
            let degraded = report.degradedFiles.map { URL(fileURLWithPath: $0.path).lastPathComponent }
            #expect(report.analyzedFileCount == 2)
            #expect(degraded == ["Bad.swift"])
            #expect(report.degradedFiles.first?.detail == "not valid UTF-8")
            #expect(report.degradedFiles.first?.skipped == true)
            #expect(!report.findings.contains { $0.path.hasSuffix("/Bad.swift") })
        }
    }

    @Test func baselineRoundTrips() throws {
        let finding = Finding(
            rule: RuleID.allCases.first!, severity: .warning,
            path: "a.swift", line: 1, column: 1, message: "m")
        let path = FileManager.default.temporaryDirectory
            .appending(path: "deadwood-bl-\(UUID().uuidString).json").path
        try Baseline(findings: [finding]).write(path: path)
        let loaded = try Baseline.load(path: path)
        #expect(loaded.contains(finding))
    }
}
