/// Answers "is this finding suppressed?" for one file's directives.
///
/// Region state is resolved with a single forward sweep per rule; directive
/// counts per file are tiny, so the O(directives) scan per query is fine.
public struct SuppressionTable: Sendable {
    private let directives: [SuppressionDirective]

    public init(directives: [SuppressionDirective]) {
        self.directives = directives.sorted { $0.line < $1.line }
    }

    /// Returns the matching directive's reason (or `.some(nil)` when suppressed
    /// without a reason); `nil` when the finding is not suppressed.
    public func suppression(for rule: RuleID, line: Int) -> String?? {
        var regionDisabled = false
        var regionReason: String?
        for directive in directives {
            switch directive.kind {
            case .acceptThis where directive.line == line && directive.covers(rule):
                return .some(directive.reason)
            case .acceptNext where directive.line == line - 1 && directive.covers(rule):
                return .some(directive.reason)
            case .accept
            where (directive.line == line || directive.line == line - 1)
                && directive.covers(rule):
                return .some(directive.reason)
            case .regionDisable where directive.line <= line && directive.covers(rule):
                regionDisabled = true
                regionReason = directive.reason
            case .regionEnable where directive.line <= line && directive.covers(rule):
                regionDisabled = false
                regionReason = nil
            default:
                break
            }
        }
        return regionDisabled ? .some(regionReason) : nil
    }
}
