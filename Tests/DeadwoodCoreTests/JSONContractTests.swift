import DeadwoodCore
import Foundation
import Testing

/// Pins the 1.x field names of the `--format json` report. The key sets are
/// the contract: a consumer reads them by name, so a renamed or removed field
/// fails here, and so does an added one, until the pinned set is updated
/// alongside `ReportSchema.version`.
@Suite struct JSONContractTests {
    private static let topLevelKeys: Set<String> = [
        "schemaVersion",
        "findings",
        "suppressed",
        "outOfScope",
        "degradedFiles",
        "analyzedFileCount",
        "cacheHits",
        "cacheMisses",
        "wasCancelled",
        "notes",
    ]

    private static let findingKeys: Set<String> = [
        "rule",
        "severity",
        "path",
        "line",
        "column",
        "message",
        "note",
        "fingerprintPath",
        "fingerprint",
    ]

    private static func object(_ report: AnalysisReport) throws -> [String: Any] {
        let text = ReportFormatter.format(report, as: .json)
        return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test("The JSON report carries the literal contract version and the 1.x field names")
    func pinsVersionAndFieldNames() throws {
        let finding = Finding(
            rule: .unusedFunction, severity: .warning,
            path: "Sources/A.swift", line: 5, column: 9,
            message: "function 'a' is never used",
            note: "declared private",
            fingerprintPath: "Sources/A.swift")
        let report = AnalysisReport(findings: [finding], analyzedFileCount: 1)

        let object = try Self.object(report)

        // The literal, not `ReportSchema.version`: a bump is a contract change and must fail here.
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(Set(object.keys) == Self.topLevelKeys)

        let findings = try #require(object["findings"] as? [[String: Any]])
        let first = try #require(findings.first)
        #expect(Set(first.keys) == Self.findingKeys)
    }

    @Test("Optional fields are omitted when nil, not encoded as null")
    func omitsNilOptionals() throws {
        let bare = Finding(
            rule: .unusedFunction, severity: .warning,
            path: "a.swift", line: 1, column: 1, message: "m")
        let report = AnalysisReport(
            findings: [bare],
            suppressed: [.init(finding: bare, reason: nil)],
            degradedFiles: [.init(path: "b.swift", detail: "d")],
            analyzedFileCount: 1)

        let object = try Self.object(report)

        let first = try #require((object["findings"] as? [[String: Any]])?.first)
        #expect(Set(first.keys) == Self.findingKeys.subtracting(["note", "fingerprintPath"]))
        let suppressed = try #require((object["suppressed"] as? [[String: Any]])?.first)
        #expect(Set(suppressed.keys) == ["finding"])
        #expect(!object.keys.contains("cacheLoadFailure"))
    }

    @Test("A set optional field is encoded with its value")
    func encodesSetOptionals() throws {
        let finding = Finding(
            rule: .unusedFunction, severity: .warning,
            path: "a.swift", line: 1, column: 1, message: "m",
            note: "n", fingerprintPath: "a.swift")
        var report = AnalysisReport(
            findings: [finding],
            suppressed: [.init(finding: finding, reason: "because")])
        report.cacheLoadFailure = "x"

        let object = try Self.object(report)

        let first = try #require((object["findings"] as? [[String: Any]])?.first)
        #expect(first["note"] as? String == "n")
        #expect(first["fingerprintPath"] as? String == "a.swift")
        let suppressed = try #require((object["suppressed"] as? [[String: Any]])?.first)
        #expect(suppressed["reason"] as? String == "because")
        #expect(object["cacheLoadFailure"] as? String == "x")
    }
}
