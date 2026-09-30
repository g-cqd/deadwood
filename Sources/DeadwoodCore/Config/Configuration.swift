public import ProjectModel

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

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
    /// Regions (comma-separated: `preview,debug,test,mock,generated,script`,
    /// or `all`) to treat as first-class code: dead code inside them is
    /// reported like any other, and a preview/debug-only note is promoted to
    /// a normal finding — never a root, which stays rooted regardless. The
    /// same key, with the same values, in deadwood, arcleak and dolly.
    public var includeRegions: String?
    /// Regions to keep out of scope even if `includeRegions` (or `all`)
    /// names them; wins where the two disagree about the same region.
    public var excludeRegions: String?

    /// Decodes a partial configuration.
    ///
    /// `rules` and `exclude` are non-optional with memberwise defaults, so the
    /// synthesized `Codable` conformance made both *required* on the wire: a
    /// config supplying only `exclude` was rejected with
    /// `keyNotFound: "rules"`. Every key is optional here, matching what the
    /// memberwise initializer already implies — which is what a CI config
    /// setting nothing but an exclude list needs.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.rules =
            try container.decodeIfPresent([String: RuleSettings].self, forKey: .rules) ?? [:]
        self.exclude = try container.decodeIfPresent([String].self, forKey: .exclude) ?? []
        self.production = try container.decodeIfPresent(Bool.self, forKey: .production)
        self.testsGlob = try container.decodeIfPresent(String.self, forKey: .testsGlob)
        self.includeRegions = try container.decodeIfPresent(String.self, forKey: .includeRegions)
        self.excludeRegions = try container.decodeIfPresent(String.self, forKey: .excludeRegions)
    }

    public init(
        rules: [String: RuleSettings] = [:],
        exclude: [String] = [],
        production: Bool? = nil,
        testsGlob: String? = nil,
        includeRegions: String? = nil,
        excludeRegions: String? = nil
    ) {
        self.rules = rules
        self.exclude = exclude
        self.production = production
        self.testsGlob = testsGlob
        self.includeRegions = includeRegions
        self.excludeRegions = excludeRegions
    }

    /// Whether production mode is on.
    public var isProductionMode: Bool { production ?? false }

    /// The parsed region selection; throws on an unknown region name from
    /// either key.
    public func regionSelection() throws(UnknownRegionName) -> RegionSelection {
        try RegionSelection(include: includeRegions, exclude: excludeRegions)
    }

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
        do {
            _ = try config.regionSelection()
        } catch {
            throw .configurationInvalid(path: path, detail: error.description)
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
