import DeadwoodCore
import Testing

/// `--minimum-confidence` narrows what a run reports. It drops the findings below
/// the level from `findings` and `outOfScope`, keeps findings with no confidence,
/// and leaves suppressed debt alone.
@Suite struct ConfidenceFilterTests {
    private static func finding(_ name: String, _ confidence: Confidence?) -> Finding {
        Finding(
            rule: .unusedFunction, severity: .warning,
            path: "Sources/\(name).swift", line: 1, column: 1, message: name,
            confidence: confidence)
    }

    @Test("Findings below the minimum are dropped and counted, and unscored findings are kept")
    func dropsFindingsBelowMinimum() {
        let report = AnalysisReport(findings: [
            Self.finding("certain", .certain),
            Self.finding("high", .high),
            Self.finding("medium", .medium),
            Self.finding("low", .low),
            Self.finding("unscored", nil),
        ])

        let filtered = report.keeping(minimumConfidence: .high)

        #expect(filtered.report.findings.map(\.message) == ["certain", "high", "unscored"])
        #expect(filtered.dropped == 2)
    }

    @Test("Out-of-scope findings are filtered by the same minimum, and do not count as dropped")
    func filtersOutOfScopeFindings() {
        var report = AnalysisReport()
        report.outOfScope = [
            Self.finding("medium", .medium),
            Self.finding("high", .high),
            Self.finding("unscored", nil),
        ]

        let filtered = report.keeping(minimumConfidence: .high)

        #expect(filtered.report.outOfScope.map(\.message) == ["high", "unscored"])
        #expect(filtered.dropped == 0)
    }

    @Test("Suppressed findings are kept whatever their confidence")
    func leavesSuppressedFindingsAlone() {
        let suppressed = AnalysisReport.SuppressedFinding(
            finding: Self.finding("low", .low), reason: "because")
        let report = AnalysisReport(suppressed: [suppressed])

        let filtered = report.keeping(minimumConfidence: .certain)

        #expect(filtered.report.suppressed.map(\.finding.message) == ["low"])
        #expect(filtered.dropped == 0)
    }
}
