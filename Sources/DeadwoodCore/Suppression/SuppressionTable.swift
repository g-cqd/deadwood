import Suppression

/// Wire-compatible facade over analyzerkit's shared line/region suppression table.
public struct SuppressionTable: Sendable {
    private let table: Suppression.SuppressionTable<RuleID>

    public init(directives: [SuppressionDirective]) {
        table = Suppression.SuppressionTable(directives: directives.map(\.shared))
    }

    /// nil: not suppressed; .some(nil): suppressed without a reason; .some(reason): suppressed with a reason.
    public func suppression(for rule: RuleID, line: Int) -> String?? {
        table.suppression(for: rule, line: line)
    }
}
