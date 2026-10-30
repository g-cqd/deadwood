import AemiJSON

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
@JSONCodable
struct ExtractedArtifacts: Sendable, Codable {
    let artifacts: CachedFileArtifacts?
    /// Over the size cap, not UTF-8, nested too deeply: the reason, as the report shows it.
    let skipped: String?

    init(artifacts: CachedFileArtifacts? = nil, skipped: String? = nil) {
        self.artifacts = artifacts
        self.skipped = skipped
    }
}

// The facts go through `CachedFileFacts`, whose references omit repeated or unused fields.
extension CachedFileArtifacts: AemiJSONFastEncodable, AemiJSONFastDecodable {
    func __adjsonEncode(into w: inout _JSONByteWriter) throws {
        w.beginObject()
        w.key("facts")
        try CachedFileFacts(facts).__adjsonEncode(into: &w)
        w.comma()
        w.key("directives")
        try w.encode(directives)
        w.comma()
        w.key("deadBranches")
        try w.encode(deadBranches)
        w.comma()
        w.key("degraded")
        try w.encode(degraded)
        w.endObject()
    }

    static func __adjsonDecode(_ c: _FastDecodeCursor) throws -> Self {
        Self(
            facts: try c.decode(CachedFileFacts.self, "facts").restored(),
            directives: try c.decode([SuppressionDirective].self, "directives"),
            deadBranches: try c.decode([UnusedCode].self, "deadBranches"),
            degraded: try c.decode([String].self, "degraded")
        )
    }
}
