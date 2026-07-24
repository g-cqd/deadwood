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

    public init(enabled: Bool = false, explicitPath: String? = nil, autoBuild: Bool = false) {
        self.enabled = enabled
        self.explicitPath = explicitPath
        self.autoBuild = autoBuild
    }

    /// The default: index mode off — today's syntax behavior, byte-identical.
    public static let disabled = Self()
}
