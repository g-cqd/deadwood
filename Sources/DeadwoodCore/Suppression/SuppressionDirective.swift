import Suppression

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
        guard let directive = grammar.parse(comment: comment, line: line, rule: RuleID.init(rawValue:)) else {
            return nil
        }
        return Self(
            rules: Set(directive.rules), kind: Kind(shared: directive.kind), line: directive.line,
            reason: directive.reason)
    }

    // Keep wire/cache models local while the shared component owns parsing and line coverage.
    static let grammar = DirectiveGrammar(namespaces: namespaces, trimming: .horizontal)

    var shared: Suppression.Directive<RuleID> {
        Suppression.Directive(rules: Array(rules), kind: kind.shared, line: line, reason: reason)
    }
}

extension SuppressionDirective.Kind {
    fileprivate init(shared: DirectiveKind) {
        switch shared {
        case .accept: self = .accept
        case .acceptThis: self = .acceptThis
        case .acceptNext: self = .acceptNext
        case .regionDisable: self = .regionDisable
        case .regionEnable: self = .regionEnable
        }
    }

    fileprivate var shared: DirectiveKind {
        switch self {
        case .accept: .accept
        case .acceptThis: .acceptThis
        case .acceptNext: .acceptNext
        case .regionDisable: .regionDisable
        case .regionEnable: .regionEnable
        }
    }
}
