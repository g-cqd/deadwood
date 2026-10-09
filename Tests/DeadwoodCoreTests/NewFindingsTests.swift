import DeadwoodCore
import Testing

/// `--report-new-since` promotes an out-of-scope finding into the report when its fingerprint is not in the
/// base branch's baseline. Only the out-of-scope list is looked at: suppressed debt is never promoted.
@Suite struct NewFindingsTests {
    private static func finding(_ name: String) -> Finding {
        Finding(
            rule: .unusedFunction, severity: .warning,
            path: "Sources/\(name).swift", line: 1, column: 1, message: name)
    }

    @Test("Promotion moves an out-of-scope finding the baseline does not hold, and keeps a known one out of scope")
    func promotesOnlyUnknownFingerprints() {
        let known = Self.finding("Known")
        let fresh = Self.finding("Fresh")
        var report = AnalysisReport(findings: [Self.finding("Changed")])
        report.outOfScope = [known, fresh]

        let promotion = NewFindings.promote(report, notIn: [known.fingerprint])

        #expect(promotion.report.findings.map(\.message) == ["Changed", "Fresh"])
        #expect(promotion.report.outOfScope.map(\.message) == ["Known"])
        #expect(promotion.promoted == [fresh.fingerprint])
    }

    @Test("An empty baseline promotes every out-of-scope finding")
    func emptyBaselinePromotesEverything() {
        var report = AnalysisReport()
        report.outOfScope = [Self.finding("First"), Self.finding("Second")]

        let promotion = NewFindings.promote(report, notIn: [])

        #expect(promotion.report.findings.map(\.message) == ["First", "Second"])
        #expect(promotion.report.outOfScope.isEmpty)
        #expect(promotion.promoted == Set(report.outOfScope.map(\.fingerprint)))
    }

    @Test("Suppressed findings are neither promoted nor changed")
    func leavesSuppressedFindingsAlone() {
        let suppressed = AnalysisReport.SuppressedFinding(finding: Self.finding("Accepted"), reason: "because")
        var report = AnalysisReport(suppressed: [suppressed])
        report.outOfScope = [Self.finding("Scoped")]

        let promotion = NewFindings.promote(report, notIn: [])

        #expect(promotion.report.suppressed.map(\.finding.message) == ["Accepted"])
        #expect(promotion.report.suppressed.map(\.reason) == ["because"])
        #expect(promotion.report.findings.map(\.message) == ["Scoped"])
        #expect(promotion.promoted == [Self.finding("Scoped").fingerprint])
    }
}
