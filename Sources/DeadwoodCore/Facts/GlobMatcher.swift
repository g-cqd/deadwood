//  Lifted from SwiftStaticAnalysis (MIT) — Utilities/GlobMatcher.swift.
//  Changes during the lift: compiled globs are cached in `RegexCache.shared`
//  (upstream recompiled per call on the slow path).

import Foundation

// MARK: - GlobMatcher

/// Single canonical glob → regex translation.
///
/// Anchored `wholeMatch` semantics: an exclusion entry like `Tests` matches
/// only the literal filename, not any path containing the segment.
///
/// Supported glob tokens:
///
/// - `**` — match any sequence of characters, including `/`.
/// - `**/` — match any number of intermediate directory segments
///   (including zero), so `**/Tests/**` matches `Tests/...` and
///   `a/b/Tests/x/y` equally.
/// - `*` — match any sequence not containing `/`.
/// - `?` — match a single character that is not `/`.
///
/// All other characters are matched literally; regex metacharacters in the
/// pattern are escaped before compilation. The compiled regex is anchored at
/// both ends and constructed through ``SafeRegex/compile(_:)`` so the length
/// cap and ReDoS prefilter apply to globs too.
enum GlobMatcher {
    /// Returns `true` when `path` matches `pattern` under glob semantics.
    /// A pattern that fails to compile does not match (defensive default).
    static func matches(path: String, pattern: String) -> Bool {
        guard let regex = compile(pattern: pattern) else { return false }
        return path.wholeMatch(of: regex) != nil
    }

    /// Like ``matches(path:pattern:)`` but routes the three most common
    /// project-level patterns through hand-tuned predicates that skip regex
    /// matching entirely.
    static func matchesWithFastPaths(path: String, pattern: String) -> Bool {
        switch pattern {
        case "**/Tests/**":
            pathMatchesTestsGlob(path)
        case "**/*Tests.swift":
            pathMatchesTestFileSuffixGlob(path)
        case "**/Fixtures/**":
            pathMatchesFixturesGlob(path)
        default:
            matches(path: path, pattern: pattern)
        }
    }

    /// Compile `pattern` to the canonical anchored regex, memoized in
    /// ``RegexCache/shared``. Returns `nil` if the translated pattern is
    /// rejected by `SafeRegex` or fails to compile.
    static func compile(pattern: String) -> Regex<AnyRegexOutput>? {
        let anchored = "^\(translate(pattern: pattern))$"
        return RegexCache.shared.regex(for: anchored)
    }

    /// Translate the glob `pattern` to the un-anchored regex body.
    static func translate(pattern: String) -> String {
        // Sentinel placeholders keep the escape pass below from touching
        // the glob wildcards themselves.
        let doubleStarSlash = "\u{0000}DOUBLE_STAR_SLASH\u{0000}"
        let doubleStar = "\u{0000}DOUBLE_STAR\u{0000}"
        let singleStar = "\u{0000}SINGLE_STAR\u{0000}"
        let question = "\u{0000}QUESTION\u{0000}"

        var working =
            pattern
            .replacingOccurrences(of: "**/", with: doubleStarSlash)
            .replacingOccurrences(of: "**", with: doubleStar)
            .replacingOccurrences(of: "*", with: singleStar)
            .replacingOccurrences(of: "?", with: question)

        // Order matters — backslash must be escaped first or it
        // double-escapes the escaping added next.
        let metaCharacters: [(needle: String, replacement: String)] = [
            ("\\", "\\\\"),
            (".", "\\."),
            ("^", "\\^"),
            ("$", "\\$"),
            ("+", "\\+"),
            ("(", "\\("),
            (")", "\\)"),
            ("[", "\\["),
            ("]", "\\]"),
            ("{", "\\{"),
            ("}", "\\}"),
            ("|", "\\|"),
        ]
        for (needle, replacement) in metaCharacters {
            working = working.replacingOccurrences(of: needle, with: replacement)
        }

        return
            working
            .replacingOccurrences(of: doubleStarSlash, with: "(?:.*/)?")
            .replacingOccurrences(of: doubleStar, with: ".*")
            .replacingOccurrences(of: singleStar, with: "[^/]*")
            .replacingOccurrences(of: question, with: "[^/]")
    }
}
