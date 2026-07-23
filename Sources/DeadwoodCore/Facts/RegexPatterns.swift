//  Lifted from SwiftStaticAnalysis (MIT) — Utilities/RegexPatterns.swift.
//  Trimmed: the `nonisolated(unsafe)` pre-compiled regex globals and the
//  USR helpers (index-store surface). What remains are the pure path/name
//  predicates the filter and glob fast paths consume.

import Foundation

// MARK: - Path helpers

/// Returns `true` when the path contains a `Tests` directory.
func pathMatchesTestsGlob(_ path: String) -> Bool {
    URL(fileURLWithPath: path).pathComponents.contains("Tests")
}

/// Returns `true` when the path ends with a `*Tests.swift` filename.
func pathMatchesTestFileSuffixGlob(_ path: String) -> Bool {
    URL(fileURLWithPath: path).lastPathComponent.hasSuffix("Tests.swift")
}

/// Returns `true` when the path contains a `Fixtures` directory.
func pathMatchesFixturesGlob(_ path: String) -> Bool {
    URL(fileURLWithPath: path).pathComponents.contains("Fixtures")
}

/// Returns `true` when the identifier is wrapped in backticks.
/// The degenerate "``" is not an identifier.
func isBacktickedIdentifier(_ identifier: String) -> Bool {
    guard identifier.count > 2, identifier.first == "`", identifier.last == "`" else {
        return false
    }

    return identifier.dropFirst().dropLast().allSatisfy { $0 != "`" }
}
