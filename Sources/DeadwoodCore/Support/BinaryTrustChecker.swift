#if canImport(IndexStoreDB)
    import IndexStoreSupport

    /// Compatibility surface; all policy and filesystem checks live in analyzerkit (ADR-0014).
    enum BinaryTrustChecker {
        static func isTrusted(at path: String) -> Bool {
            IndexStoreSupport.BinaryTrustChecker.isTrusted(at: path)
        }
    }
#endif
