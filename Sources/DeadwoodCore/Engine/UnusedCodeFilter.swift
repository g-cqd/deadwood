//  Lifted from SwiftStaticAnalysis (MIT) — UnusedCodeDetector/Filters/UnusedCodeFilter.swift.
//  Changes during the lift: the `swa:ignore` directive hook is gone —
//  deadwood suppression is the `@dw:` table applied by the Analyzer after
//  mapping. The `production()` preset and array conveniences are trimmed.

// MARK: - UnusedCodeFilterConfiguration

/// Configuration for filtering unused code results.
struct UnusedCodeFilterConfiguration: Sendable {
    /// Sensible defaults that exclude common false positives.
    static let sensibleDefaults = Self(
        excludeDeinit: true,
        excludeBacktickedEnumCases: true,
        excludeTestSuites: true
    )

    /// Exclude import statements.
    var excludeImports: Bool

    /// Exclude deinit methods.
    var excludeDeinit: Bool

    /// Exclude backticked enum cases (Swift keywords used as identifiers).
    var excludeBacktickedEnumCases: Bool

    /// Exclude test suite declarations (names ending with "Tests"/"Test").
    var excludeTestSuites: Bool

    init(
        excludeImports: Bool = false,
        excludeDeinit: Bool = false,
        excludeBacktickedEnumCases: Bool = false,
        excludeTestSuites: Bool = false
    ) {
        self.excludeImports = excludeImports
        self.excludeDeinit = excludeDeinit
        self.excludeBacktickedEnumCases = excludeBacktickedEnumCases
        self.excludeTestSuites = excludeTestSuites
    }
}

// MARK: - UnusedCodeFilter

/// Filters unused code results to exclude false positives.
struct UnusedCodeFilter: Sendable {
    /// Filter configuration.
    let configuration: UnusedCodeFilterConfiguration

    init(configuration: UnusedCodeFilterConfiguration) {
        self.configuration = configuration
    }

    // MARK: - Helpers

    /// Check if a name looks like a test suite.
    static func isTestSuiteName(_ name: String) -> Bool {
        name.hasSuffix("Tests") || name.hasSuffix("Test")
    }

    // MARK: - Filtering

    /// Filter unused code results, removing likely false positives.
    func filter(_ results: [UnusedCode]) -> [UnusedCode] {
        results.filter { !shouldExclude($0) }
    }

    /// Check if a result should be excluded.
    func shouldExclude(_ item: UnusedCode) -> Bool {
        let name = item.declaration.name

        // Underscore is Swift's "discard this value" identifier.
        if name == "_" {
            return true
        }

        if configuration.excludeImports, item.declaration.kind == .import {
            return true
        }

        if configuration.excludeDeinit, name == "deinit" {
            return true
        }

        if configuration.excludeBacktickedEnumCases, isBacktickedIdentifier(name) {
            return true
        }

        if configuration.excludeTestSuites, Self.isTestSuiteName(name) {
            return true
        }

        return false
    }
}
