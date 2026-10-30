//  New in deadwood: the CLI-facing switches for the opt-in `--index-store`
//  reachability mode. Deliberately free of any IndexStoreDB type so it
//  compiles on Linux (where the flag simply produces the graceful-fallback
//  note) and threads cleanly through the public `Analyzer` surface.

/// Options controlling the index-backed reachability mode.
public struct IndexStoreOptions: Sendable, Equatable {
    /// Whether `--index-store` was requested.
    public var enabled: Bool

    /// Explicit index-store path (`--index-store-path`); nil = discover under
    /// the project's `.build/.../index/store` or Xcode DerivedData.
    public var explicitPath: String?

    /// Whether to build the project to generate an index if none is found
    /// (`--index-store-build`).
    public var autoBuild: Bool

    /// The cache root the index database lives under (analyzerkit ADR-0004); nil uses the tool's directory in the user
    /// cache directory.
    public var cacheRoot: String?

    /// `--verbose`: the index summary also counts the symbols with no index reference, a pass of its own (D5).
    public var verbose: Bool

    public init(
        enabled: Bool = false, explicitPath: String? = nil, autoBuild: Bool = false, cacheRoot: String? = nil,
        verbose: Bool = false
    ) {
        self.enabled = enabled
        self.explicitPath = explicitPath
        self.autoBuild = autoBuild
        self.cacheRoot = cacheRoot
        self.verbose = verbose
    }

    /// The default: index mode off — today's syntax behavior, byte-identical.
    public static let disabled = Self()
}
