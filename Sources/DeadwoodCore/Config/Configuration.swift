import Foundation

/// Analyzer configuration, loadable from `.deadwood.json`.
///
/// Malformed configuration is a hard, typed failure — the analyzer fails
/// closed rather than running with rules silently dropped.
public struct Configuration: Sendable, Codable, Equatable {
    public struct RuleSettings: Sendable, Codable, Equatable {
        public var enabled: Bool?
        public var severity: Severity?

        public init(enabled: Bool? = nil, severity: Severity? = nil) {
            self.enabled = enabled
            self.severity = severity
        }
    }

    /// Keyed by `RuleID` raw value. Unknown keys are rejected at load time so
    /// a typo can't silently disable nothing.
    public var rules: [String: RuleSettings]
    /// Path substrings to exclude (matched against the file path).
    public var exclude: [String]
    /// Production mode: corpus reachability runs twice (with and without
    /// test roots); declarations only tests can reach get the
    /// `referenced-only-by-tests` rule. Absent means off.
    public var production: Bool?
    /// Glob deciding which files count as test files in production mode;
    /// absent uses the built-in `**/Tests/**` + `**/*Tests.swift`
    /// heuristics.
    public var testsGlob: String?

    public init(
        rules: [String: RuleSettings] = [:],
        exclude: [String] = [],
        production: Bool? = nil,
        testsGlob: String? = nil
    ) {
        self.rules = rules
        self.exclude = exclude
        self.production = production
        self.testsGlob = testsGlob
    }

    /// Whether production mode is on.
    public var isProductionMode: Bool { production ?? false }

    public static let `default` = Configuration()

    public static func load(path: String) throws(DeadwoodError) -> Configuration {
        let data = try BoundedFileReader.read(path: path)
        let config: Configuration
        do {
            config = try JSONDecoder().decode(Configuration.self, from: data)
        } catch {
            throw .configurationInvalid(path: path, detail: String(describing: error))
        }
        if let bogus = config.rules.keys.first(where: { RuleID(rawValue: $0) == nil }) {
            throw .configurationInvalid(path: path, detail: "unknown rule id \"\(bogus)\"")
        }
        return config
    }

    public func isEnabled(_ rule: RuleID) -> Bool {
        rules[rule.rawValue]?.enabled ?? rule.enabledByDefault
    }

    public func severity(for rule: RuleID) -> Severity {
        rules[rule.rawValue]?.severity ?? rule.defaultSeverity
    }

    /// Whether the path is excluded from analysis. Entries containing glob
    /// wildcards (`*`, `?`) match with anchored glob semantics through
    /// `GlobMatcher`; plain entries keep their substring semantics.
    public func isExcluded(path: String) -> Bool {
        exclude.contains { entry in
            guard !entry.isEmpty else { return false }
            if entry.contains("*") || entry.contains("?") {
                return GlobMatcher.matchesWithFastPaths(path: path, pattern: entry)
            }
            return path.contains(entry)
        }
    }
}
