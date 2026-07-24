public import ADJSON
import Foundation

/// One parsed `@dw:` / `@deadwood:` directive comment.
///
/// The `@` sigil marks an instruction to the analyzer; `dw` and `deadwood` are
/// interchangeable namespaces. Grammar (whitespace-tolerant, rule ids comma-
/// or space-separated; `all` or no rule = every rule):
///
///     // @dw:accept [rules] [-- reason]        accept the finding here AND on
///                                              the next line (works trailing
///                                              or on the line above the code)
///     // @dw:accept:this [rules] [-- reason]   this line only
///     // @dw:accept:next [rules] [-- reason]   next line only
///     // @dw:disable [rules|all]               region start (to EOF if unbalanced)
///     // @dw:enable  [rules|all]               region end
///
/// `@deadwood:` is an exact synonym for `@dw:`.
@JSONCodable
public struct SuppressionDirective: Sendable, Equatable, Codable {
    public enum Kind: Sendable, Equatable, Codable {
        case acceptThis
        case acceptNext
        /// `@dw:accept` — covers its own line *and* the next, so it works both
        /// as a trailing comment and on the line above the flagged code.
        case accept
        case regionDisable
        case regionEnable
    }

    /// The accepted namespace prefixes after the `@` sigil.
    public static let namespaces = ["dw:", "deadwood:"]

    /// Empty set means "all rules".
    public let rules: Set<RuleID>
    public let kind: Kind
    /// 1-based line the comment appears on.
    public let line: Int
    public let reason: String?

    public init(rules: Set<RuleID>, kind: Kind, line: Int, reason: String?) {
        self.rules = rules
        self.kind = kind
        self.line = line
        self.reason = reason
    }

    public func covers(_ rule: RuleID) -> Bool {
        rules.isEmpty || rules.contains(rule)
    }

    /// Parses one comment. Returns nil when it isn't an `@dw:`/`@deadwood:`
    /// directive. Unknown rule ids inside a directive are ignored (they may
    /// belong to a future version) — but if a rule-scoped verb names *only*
    /// unknown rules, the directive suppresses nothing rather than everything.
    public static func parse(comment: String, line: Int) -> SuppressionDirective? {
        var text = comment
        if text.hasPrefix("//") { text.removeFirst(2) }
        if text.hasPrefix("/*") { text.removeFirst(2) }
        if text.hasSuffix("*/") { text.removeLast(2) }
        text = text.trimmingCharacters(in: .whitespaces)

        guard text.hasPrefix("@") else { return nil }
        text.removeFirst()
        guard let namespace = namespaces.first(where: text.hasPrefix) else { return nil }
        text.removeFirst(namespace.count)

        var reason: String?
        if let range = text.range(of: "--") {
            reason = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            text = String(text[..<range.lowerBound])
        }
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let verb = parts.first else { return nil }
        let ruleWords = parts.dropFirst().flatMap { $0.split(separator: ",").map(String.init) }

        let kind: Kind
        switch verb {
        case "accept": kind = .accept
        case "accept:this": kind = .acceptThis
        case "accept:next": kind = .acceptNext
        case "disable": kind = .regionDisable
        case "enable": kind = .regionEnable
        default: return nil
        }

        if ruleWords.contains("all") || ruleWords.isEmpty {
            return SuppressionDirective(rules: [], kind: kind, line: line, reason: reason)
        }
        let rules = Set(ruleWords.compactMap(RuleID.init(rawValue:)))
        guard !rules.isEmpty else { return nil }
        return SuppressionDirective(rules: rules, kind: kind, line: line, reason: reason)
    }
}
