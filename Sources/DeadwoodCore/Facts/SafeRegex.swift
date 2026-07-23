//  Lifted from SwiftStaticAnalysis (MIT) — Utilities/SafeRegex.swift.
//  Changes during the lift: the antipattern probes were `nonisolated(unsafe)`
//  static regexes upstream; they are rebuilt per validation call here so the
//  module carries no unsafe globals (validation is rare and the probes are
//  trivial to construct).

import RegexBuilder

// MARK: - SafeRegex

/// Single canonical entry point for compiling regex patterns that originate
/// outside the tool (configuration globs, name filters).
///
/// `SafeRegex.compile` provides two pre-emptive guards against catastrophic
/// backtracking ("ReDoS"):
///
/// 1. **Length cap.** Patterns longer than ``maxPatternLength`` are rejected
///    outright; 512 bytes is large enough for every sensible glob and tight
///    enough to bound worst-case compilation cost.
/// 2. **Static antipattern prefilter.** Catches the canonical
///    nested-quantifier shapes `(...*)*` / `(...+)+` and the `(.*)*` /
///    `(.*)+` catch-all repetition recipe. The prefilter is a best-effort
///    signal, not a comprehensive ReDoS oracle.
enum SafeRegex {
    /// Maximum allowed UTF-8 length of a pattern, in bytes.
    static let maxPatternLength = 512

    /// Reasons `compile` rejects a pattern.
    enum Failure: Error, Sendable, CustomStringConvertible {
        case tooLong(actual: Int, limit: Int)
        case antipattern(reason: String)
        case invalid(underlying: String)

        var description: String {
            switch self {
            case .tooLong(let actual, let limit):
                "Refusing regex pattern of \(actual) bytes (limit \(limit))."
            case .antipattern(let reason):
                "Refusing regex pattern: \(reason)"
            case .invalid(let underlying):
                "Invalid regex pattern: \(underlying)"
            }
        }
    }

    /// Compile a pattern after applying the length cap and the
    /// nested-quantifier prefilter.
    static func compile(_ pattern: String) throws -> Regex<AnyRegexOutput> {
        try validate(pattern)
        do {
            return try Regex(pattern)
        } catch {
            throw Failure.invalid(underlying: String(describing: error))
        }
    }

    /// Validate a pattern without compiling it.
    static func validate(_ pattern: String) throws {
        let byteCount = pattern.utf8.count
        if byteCount > maxPatternLength {
            throw Failure.tooLong(actual: byteCount, limit: maxPatternLength)
        }
        for antipattern in Self.antipatterns() where pattern.contains(antipattern) {
            throw Failure.antipattern(
                reason: "contains a nested-quantifier construct known for catastrophic backtracking.")
        }
    }

    /// Antipattern probes expressed with `RegexBuilder`. Each entry catches
    /// a known ReDoS recipe:
    ///
    /// - **nested quantifier group**: `(...*...)` or `(...+...)` followed by
    ///   another `*`/`+` — the canonical "evil regex" (`(a+)+`, `(.+)*`).
    /// - **catch-all repetition**: literal `(.*)` followed by `*`/`+`.
    private static func antipatterns() -> [Regex<AnyRegexOutput>] {
        [
            Regex(
                Regex {
                    "("
                    ZeroOrMore(CharacterClass.anyOf(")").inverted)
                    One(.anyOf("*+"))
                    ZeroOrMore(CharacterClass.anyOf(")").inverted)
                    ")"
                    ZeroOrMore(.whitespace)
                    One(.anyOf("*+"))
                }),
            Regex(
                Regex {
                    "(.*)"
                    ZeroOrMore(.whitespace)
                    One(.anyOf("*+"))
                }),
        ]
    }
}
