import DeadwoodCore
import Testing

@Suite struct SuppressionTests {
    @Test func parsesAccept() {
        let directive = SuppressionDirective.parse(
            comment: "// @dw:accept -- reviewed", line: 3)
        #expect(directive?.kind == .accept)
        #expect(directive?.reason == "reviewed")
        #expect(directive?.rules.isEmpty == true)
    }

    @Test func longNamespaceIsSynonym() {
        let directive = SuppressionDirective.parse(
            comment: "// @deadwood:accept:next unused-function", line: 1)
        #expect(directive?.kind == .acceptNext)
        #expect(directive?.rules == [RuleID(rawValue: "unused-function")!])
    }

    @Test func rejectsMissingSigil() {
        #expect(SuppressionDirective.parse(comment: "// dw:accept", line: 1) == nil)
    }

    @Test func rejectsExpectationSigil() {
        #expect(SuppressionDirective.parse(comment: "// #dw:expect unused-function", line: 1) == nil)
    }

    @Test func unknownOnlyRulesSuppressNothing() {
        #expect(SuppressionDirective.parse(comment: "// @dw:accept:this bogus-rule", line: 1) == nil)
    }

    @Test func regionPairScopesSuppression() {
        let table = SuppressionTable(directives: [
            SuppressionDirective(rules: [], kind: .regionDisable, line: 2, reason: "generated"),
            SuppressionDirective(rules: [], kind: .regionEnable, line: 8, reason: nil),
        ])
        let rule = RuleID.allCases.first!
        #expect(table.suppression(for: rule, line: 5) == .some("generated"))
        #expect(table.suppression(for: rule, line: 9) == nil)
    }
}
