//  Lifted from SwiftStaticAnalysis (MIT) — Utilities/RegexCache.swift.
//  Changes during the lift:
//  - `LRUDictionary` (swift-collections OrderedDictionary) replaced by a
//    plain Dictionary with whole-cache reset at capacity.
//  - `Regex` is not Sendable on current toolchains, so a compiled program
//    cannot legally cross the mutex boundary under strict region isolation.
//    The cache therefore memoizes the *validation verdict* per pattern and
//    recompiles on use: known-bad patterns short-circuit without touching
//    the regex engine, known-good ones skip `SafeRegex` validation. Glob
//    hot paths bypass regexes entirely (`GlobMatcher.matchesWithFastPaths`),
//    and `CompiledPatterns` pre-compiles fixed pattern sets once, so the
//    per-call compile only occurs on rare slow paths.

import Synchronization

// MARK: - RegexCache

/// Thread-safe memo of which regex patterns are valid, so repeated slow-path
/// glob matches don't re-run validation or re-fail compilation.
final class RegexCache: Sendable {
    /// Shared cache instance for common patterns.
    static let shared = RegexCache()

    private let capacity: Int
    private let verdicts: Mutex<[String: Bool]>

    /// Creates a new regex cache.
    ///
    /// - Parameter capacity: Maximum number of verdicts to retain before
    ///   the cache resets. Defaults to 256.
    init(capacity: Int = 256) {
        self.capacity = max(1, capacity)
        self.verdicts = Mutex([:])
    }

    /// Compiles a regex for the given pattern; nil when the pattern is
    /// invalid or rejected by ``SafeRegex``. Known-bad patterns return nil
    /// without touching the regex engine again.
    func regex(for pattern: String) -> Regex<AnyRegexOutput>? {
        let verdict = verdicts.withLock { $0[pattern] }
        if verdict == false {
            return nil
        }

        let compiled: Regex<AnyRegexOutput>?
        if verdict == true {
            // Validation already passed; plain compilation cannot regress.
            compiled = try? Regex(pattern)
        } else {
            compiled = try? SafeRegex.compile(pattern)
        }

        if verdict == nil {
            verdicts.withLock { cache in
                if cache.count >= capacity {
                    cache.removeAll(keepingCapacity: true)
                }
                cache[pattern] = compiled != nil
            }
        }
        return compiled
    }
}

// MARK: - CompiledPatterns

/// Pre-compiled collection of regex patterns, compiled once at
/// initialization. Invalid patterns are silently ignored.
///
/// Safe to use concurrently because the patterns are immutable after init.
struct CompiledPatterns: @unchecked Sendable {
    /// The compiled regex patterns (immutable after init).
    private let compiled: [Regex<AnyRegexOutput>]

    init(_ patterns: [String]) {
        compiled = patterns.compactMap { pattern in
            try? SafeRegex.compile(pattern)
        }
    }

    /// Whether any of the patterns match (substring semantics) the string.
    func anyMatches(_ string: String) -> Bool {
        compiled.contains { string.contains($0) }
    }
}
