public import Suppression

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
public typealias SuppressionDirective = Suppression.Directive<RuleID>

extension Suppression.Directive where Rule == RuleID {
    /// The accepted namespace prefixes after the `@` sigil.
    public static var namespaces: [String] { deadwoodDirectiveNamespaces }

    /// Parses one comment. Returns nil when it isn't an `@dw:`/`@deadwood:`
    /// directive. Unknown rule ids inside a directive are ignored (they may
    /// belong to a future version) — but if a rule-scoped verb names *only*
    /// unknown rules, the directive suppresses nothing rather than everything.
    public static func parse(comment: String, line: Int) -> Self? {
        grammar.parse(comment: comment, line: line, rule: RuleID.init(rawValue:))
    }

    static var grammar: DirectiveGrammar { deadwoodDirectiveGrammar }
}

// Stored once: a generic type cannot hold a static stored property.
private let deadwoodDirectiveNamespaces = ["dw:", "deadwood:"]
private let deadwoodDirectiveGrammar = DirectiveGrammar(namespaces: deadwoodDirectiveNamespaces, trimming: .horizontal)
