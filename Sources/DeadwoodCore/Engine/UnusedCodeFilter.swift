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

    /// Path patterns to exclude (glob syntax).
    var excludePathPatterns: [String]

    /// Name patterns to exclude (regex).
    var excludeNamePatterns: [String]

    init(
        excludeImports: Bool = false,
        excludeDeinit: Bool = false,
        excludeBacktickedEnumCases: Bool = false,
        excludeTestSuites: Bool = false,
        excludePathPatterns: [String] = [],
        excludeNamePatterns: [String] = []
    ) {
        self.excludeImports = excludeImports
        self.excludeDeinit = excludeDeinit
        self.excludeBacktickedEnumCases = excludeBacktickedEnumCases
        self.excludeTestSuites = excludeTestSuites
        self.excludePathPatterns = excludePathPatterns
        self.excludeNamePatterns = excludeNamePatterns
    }
}

// MARK: - UnusedCodeFilter

/// Filters unused code results to exclude false positives.
struct UnusedCodeFilter: Sendable {
    /// Filter configuration.
    let configuration: UnusedCodeFilterConfiguration

    /// Pre-compiled custom path patterns (anchored whole-match globs).
    private let compiledPathPatterns: CompiledPatterns

    /// Pre-compiled name patterns.
    private let namePatterns: CompiledPatterns

    init(configuration: UnusedCodeFilterConfiguration) {
        self.configuration = configuration

        // Custom path globs go through the canonical `GlobMatcher`
        // translation, anchored so substring matching behaves as a whole
        // match. The three common globs are handled by fast paths instead.
        compiledPathPatterns = CompiledPatterns(
            configuration.excludePathPatterns
                .filter { !Self.isCommonGlob($0) }
                .map { "^\(GlobMatcher.translate(pattern: $0))$" }
        )
        namePatterns = CompiledPatterns(configuration.excludeNamePatterns)
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
        let filePath = item.declaration.location.file

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

        for pattern in configuration.excludePathPatterns {
            switch pattern {
            case "**/Tests/**":
                if pathMatchesTestsGlob(filePath) { return true }
            case "**/*Tests.swift":
                if pathMatchesTestFileSuffixGlob(filePath) { return true }
            case "**/Fixtures/**":
                if pathMatchesFixturesGlob(filePath) { return true }
            default:
                break
            }
        }

        if compiledPathPatterns.anyMatches(filePath) {
            return true
        }

        return namePatterns.anyMatches(name)
    }

    private static func isCommonGlob(_ pattern: String) -> Bool {
        switch pattern {
        case "**/Tests/**", "**/*Tests.swift", "**/Fixtures/**":
            true
        default:
            false
        }
    }
}
