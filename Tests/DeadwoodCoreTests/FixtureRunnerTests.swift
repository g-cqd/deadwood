import DeadwoodCore
import Foundation
import Testing

/// Golden gate over the fixture corpus. `Clean/` fixtures must produce zero
/// findings (the false-positive gate); `Findings/` fixtures declare their
/// expected findings with `// #dw:expect <rule>` markers on the finding line.
@Suite struct FixtureRunnerTests {
    private static let fixtureRoot = Bundle.module.resourceURL!
        .appending(path: "Fixtures")

    private func expectations(in source: String, verb: String) -> [(line: Int, rule: String)] {
        var result: [(Int, String)] = []
        for (index, lineText) in source.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
        {
            for marker in ["#dw:\(verb) ", "#deadwood:\(verb) "] {
                guard let range = lineText.range(of: marker) else { continue }
                let rule =
                    lineText[range.upperBound...]
                    .split(separator: " ").first.map(String.init) ?? ""
                result.append((index + 1, rule))
            }
        }
        return result
    }

    @Test("Clean fixtures: zero findings (false-positive gate)")
    func cleanFixturesStayClean() throws {
        let cleanDir = Self.fixtureRoot.appending(path: "Clean")
        let files = try FileManager.default.contentsOfDirectory(
            at: cleanDir, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let report = Analyzer().analyze(source: source, path: file.lastPathComponent)
            #expect(
                report.findings.isEmpty,
                "unexpected findings in \(file.lastPathComponent): \(report.findings)")
        }
    }

    @Test("Findings fixtures: exact expected finding sets")
    func findingsFixturesMatchExpectations() throws {
        let dir = Self.fixtureRoot.appending(path: "Findings")
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let report = Analyzer().analyze(source: source, path: file.lastPathComponent)
            let expected = expectations(in: source, verb: "expect")
                .map { "\($0.line):\($0.rule)" }.sorted()
            let actual = report.findings.map { "\($0.line):\($0.rule.rawValue)" }.sorted()
            #expect(
                actual == expected,
                "\(file.lastPathComponent): expected \(expected), got \(actual)")
        }
    }
}
