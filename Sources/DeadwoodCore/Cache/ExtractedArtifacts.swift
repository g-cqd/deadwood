/// Everything one parse of a file produces (facts, directives, dataflow findings, degraded notes), exactly what the
/// Analyzer's per-file phase computes, so a cache hit skips the parse and every per-file walk. The corpus-wide
/// graph/BFS and every rule always re-run: findings can never go stale relative to rules or configuration.
struct CachedFileArtifacts: Sendable, Codable {
    let facts: FileAnalysisResult
    let directives: [SuppressionDirective]
    let deadBranches: [UnusedCode]
    let degraded: [String]
}

/// What analyzerkit's facts cache keeps for one file (roadmap 0019): its artifacts, or why it was not analysed.
struct ExtractedArtifacts: Sendable, Codable {
    let artifacts: CachedFileArtifacts?
    /// Over the size cap, not UTF-8, nested too deeply: the reason, as the report shows it.
    let skipped: String?

    init(artifacts: CachedFileArtifacts? = nil, skipped: String? = nil) {
        self.artifacts = artifacts
        self.skipped = skipped
    }
}
