//  Lifted from SwiftStaticAnalysis (MIT) — UnusedCodeDetector/Configuration/UnusedCodeConfiguration.swift.
//  Trimmed: index-store fields (indexStorePath, autoBuild, sandbox/hybrid/
//  stale-index switches), incremental-cache fields, and the AnalysisLogger —
//  none of that surface exists in deadwood.

// MARK: - UnusedCodeConfiguration

/// Configuration for unused code detection.
struct UnusedCodeConfiguration: Sendable {
    /// Default configuration.
    static let `default` = Self()

    /// Detect unused variables/constants.
    var detectVariables: Bool

    /// Detect unused functions/methods.
    var detectFunctions: Bool

    /// Detect unused types.
    var detectTypes: Bool

    /// Detect unused imports (behind the `unused-import` rule).
    var detectImports: Bool

    /// Detect assign-only properties (behind the `assign-only-property`
    /// rule).
    var detectAssignOnly: Bool

    /// Production mode: run reachability twice (with and without test
    /// roots) and split declarations only tests can reach into the
    /// `referenced-only-by-tests` rule.
    var productionMode: Bool

    /// Glob deciding which files are test files in production mode; nil
    /// uses the built-in heuristics (`**/Tests/**`, `**/*Tests.swift`).
    var testsGlob: String?

    /// Detection mode to use.
    var mode: DetectionMode

    /// Minimum confidence level to report.
    var minimumConfidence: Confidence

    /// Patterns to ignore (regex for declaration names).
    var ignoredPatterns: [String]

    /// Treat public API as entry points. Wired to the inverse of the
    /// `unused-public-api` rule toggle.
    var treatPublicAsRoot: Bool

    /// Treat @objc declarations as entry points.
    var treatObjcAsRoot: Bool

    /// Treat test methods as entry points.
    var treatTestsAsRoot: Bool

    /// Treat SwiftUI Views as entry points (body is always used).
    var treatSwiftUIViewsAsRoot: Bool

    /// Ignore SwiftUI property wrappers (@State, @Binding, ...).
    var ignoreSwiftUIPropertyWrappers: Bool

    /// Ignore PreviewProvider implementations.
    var ignorePreviewProviders: Bool

    /// Ignore View `body` properties.
    var ignoreViewBody: Bool

    /// Treat declarations visible outside the analyzed file(s) as roots.
    /// Single-file analysis sets this: an `internal` declaration can be
    /// used from any other file in its module, so one file alone can never
    /// prove it unused.
    var treatVisibleOutsideFileAsRoot: Bool

    /// Override for the parallel-BFS routing decision:
    /// nil = auto-select against `parallelBFSThreshold`, true/false = force.
    var useParallelBFS: Bool?

    /// Node-count threshold above which the auto-select path uses parallel
    /// BFS. Only consulted when `useParallelBFS == nil`.
    var parallelBFSThreshold: Int

    init(
        detectVariables: Bool = true,
        detectFunctions: Bool = true,
        detectTypes: Bool = true,
        detectImports: Bool = false,
        detectAssignOnly: Bool = false,
        productionMode: Bool = false,
        testsGlob: String? = nil,
        mode: DetectionMode = .reachability,
        minimumConfidence: Confidence = .low,
        ignoredPatterns: [String] = [],
        treatPublicAsRoot: Bool = true,
        treatObjcAsRoot: Bool = true,
        treatTestsAsRoot: Bool = true,
        treatSwiftUIViewsAsRoot: Bool = true,
        ignoreSwiftUIPropertyWrappers: Bool = true,
        ignorePreviewProviders: Bool = true,
        ignoreViewBody: Bool = true,
        treatVisibleOutsideFileAsRoot: Bool = false,
        useParallelBFS: Bool? = nil,
        parallelBFSThreshold: Int = 1000
    ) {
        self.detectVariables = detectVariables
        self.detectFunctions = detectFunctions
        self.detectTypes = detectTypes
        self.detectImports = detectImports
        self.detectAssignOnly = detectAssignOnly
        self.productionMode = productionMode
        self.testsGlob = testsGlob
        self.mode = mode
        self.minimumConfidence = minimumConfidence
        self.ignoredPatterns = ignoredPatterns
        self.treatPublicAsRoot = treatPublicAsRoot
        self.treatObjcAsRoot = treatObjcAsRoot
        self.treatTestsAsRoot = treatTestsAsRoot
        self.treatSwiftUIViewsAsRoot = treatSwiftUIViewsAsRoot
        self.ignoreSwiftUIPropertyWrappers = ignoreSwiftUIPropertyWrappers
        self.ignorePreviewProviders = ignorePreviewProviders
        self.ignoreViewBody = ignoreViewBody
        self.treatVisibleOutsideFileAsRoot = treatVisibleOutsideFileAsRoot
        self.useParallelBFS = useParallelBFS
        self.parallelBFSThreshold = max(1, parallelBFSThreshold)
    }

    /// The root-detection configuration this detection config implies.
    var rootDetection: RootDetectionConfiguration {
        RootDetectionConfiguration(
            treatPublicAsRoot: treatPublicAsRoot,
            treatObjcAsRoot: treatObjcAsRoot,
            treatTestsAsRoot: treatTestsAsRoot,
            treatSwiftUIViewsAsRoot: treatSwiftUIViewsAsRoot,
            treatSwiftUIPropertyWrappersAsRoot: ignoreSwiftUIPropertyWrappers,
            treatPreviewProvidersAsRoot: ignorePreviewProviders,
            treatVisibleOutsideFileAsRoot: treatVisibleOutsideFileAsRoot
        )
    }
}
