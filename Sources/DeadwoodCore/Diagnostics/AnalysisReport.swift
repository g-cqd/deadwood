/// The complete result of one analysis run.
public struct AnalysisReport: Sendable, Codable {
    public var findings: [Finding]
    /// Findings that matched a suppression directive; kept so suppression debt is visible.
    public var suppressed: [SuppressedFinding]
    /// Files that failed to read or parse cleanly (analysis continued on the error-tolerant tree
    /// or skipped the file; either way the run is marked degraded, never silently complete).
    public var degradedFiles: [DegradedFile]
    public var analyzedFileCount: Int
    /// Facts served from the incremental cache vs freshly parsed (0/0 when no
    /// cache was configured).
    public var cacheHits = 0
    public var cacheMisses = 0

    public init(
        findings: [Finding] = [],
        suppressed: [SuppressedFinding] = [],
        degradedFiles: [DegradedFile] = [],
        analyzedFileCount: Int = 0
    ) {
        self.findings = findings
        self.suppressed = suppressed
        self.degradedFiles = degradedFiles
        self.analyzedFileCount = analyzedFileCount
    }

    public var maxSeverity: Severity? { findings.map(\.severity).max() }

    public struct SuppressedFinding: Sendable, Codable {
        public let finding: Finding
        /// The reason text from `-- reason`, if the author gave one.
        public let reason: String?

        public init(finding: Finding, reason: String?) {
            self.finding = finding
            self.reason = reason
        }
    }

    public struct DegradedFile: Sendable, Codable {
        public let path: String
        public let detail: String

        public init(path: String, detail: String) {
            self.path = path
            self.detail = detail
        }
    }
}
