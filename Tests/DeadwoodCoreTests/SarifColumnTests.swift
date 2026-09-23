import DeadwoodCore
import Foundation
import Testing

/// SARIF regions count columns in UTF-16 code units, while deadwood's own
/// columns are swift-syntax's 1-based UTF-8 byte offsets. Converting one to
/// the other must land on the line swift-syntax counted, whatever the line
/// endings, and must not count a byte-order mark (SARIF 2.1.0 §3.30.2).
@Suite struct SarifColumnTests {
    /// A finding after text that UTF-8 and UTF-16 count differently.
    private static func line(declaring name: String) -> String {
        #"let marker = "😀é"; private func "# + name + "() {}"
    }

    @Test("Line endings and a byte-order mark do not move a column")
    func lineEndingsAndByteOrderMark() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "deadwood-columns-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sources = [
            "Crlf.swift": ["// CRLF", Self.line(declaring: "unusedCrlf"), ""].joined(separator: "\r\n"),
            "Cr.swift": ["// CR", Self.line(declaring: "unusedCr"), ""].joined(separator: "\r"),
            "Bom.swift": "\u{FEFF}" + Self.line(declaring: "unusedBom") + "\n",
        ]
        for (name, source) in sources {
            try source.write(to: dir.appending(path: name), atomically: true, encoding: .utf8)
        }
        let report = await Analyzer().analyze(files: sources.keys.map { dir.appending(path: $0).path })

        let log = try JSONDecoder().decode(
            SarifLog.self, from: Data(ReportFormatter.format(report, as: .sarif).utf8))
        let columns = log.results.filter { $0.ruleId == "unused-function" }
            .flatMap { $0.locations.map(\.physicalLocation.region.startColumn) }
        let expected = try Workspace.utf16Column(of: "private func", in: Self.line(declaring: "unusedCr"))
        #expect(columns == [expected, expected, expected])
    }

    @Test("A location whose file cannot be read keeps its byte column")
    func unreadableFileKeepsColumn() throws {
        let report = Analyzer().analyze(source: Self.line(declaring: "unusedGone") + "\n", path: "Gone.swift")
        let finding = try #require(report.findings.first { $0.rule == .unusedFunction })
        #expect(finding.column > 1)

        let log = try JSONDecoder().decode(
            SarifLog.self, from: Data(ReportFormatter.format(report, as: .sarif).utf8))
        let result = try #require(log.results.first { $0.ruleId == "unused-function" })
        #expect(result.locations.first?.physicalLocation.region.startColumn == finding.column)
    }
}
