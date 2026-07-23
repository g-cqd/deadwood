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
