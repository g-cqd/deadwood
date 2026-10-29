#if canImport(IndexStoreDB)
    import IndexStoreSupport
#endif

/// Verbose toolchain discovery diagnostics, independent of whether an index store can be opened.
/// Describes selection, not a claim that dlopen or index coverage succeeded.
public enum IndexToolchainDiagnostics {
    public static func resolve() -> [String] {
        #if canImport(IndexStoreDB)
            ToolchainResolution.resolve().diagnostics
        #else
            ["index-store toolchain resolution is macOS-only"]
        #endif
    }
}
