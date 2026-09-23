/// The complete result of one analysis run.
public struct AnalysisReport: Sendable, Codable {
    public var findings: [Finding]
    /// Findings that matched a suppression directive; kept so suppression debt is visible.
    public var suppressed: [SuppressedFinding]
    /// Findings the engine produced that fell outside the configured
    /// ``ReportScope``. Empty when no scope was set. Kept rather than dropped
    /// so a scoped run never looks like a clean one.
    public var outOfScope: [Finding] = []
    /// Files that failed to read, or whose analysis was cut short (a function
    /// over the dead-branch statement bound); either way the run is marked
    /// degraded, never silently complete. ``DegradedFile/skipped`` tells the
    /// two apart.
    public var degradedFiles: [DegradedFile]
    public var analyzedFileCount: Int
    /// Facts served from the incremental cache vs freshly parsed (0/0 when no
    /// cache was configured).
    public var cacheHits = 0
    public var cacheMisses = 0

    /// Set when the run was cancelled before the corpus was complete.
    ///
    /// A whole-program analysis over a *partial* corpus does not merely report
    /// less — it reports wrongly, because "no reference anywhere" and "no clone
    /// elsewhere" are both conclusions drawn from the corpus being whole. A
    /// cancelled run therefore carries no findings at all, and callers must treat
    /// it as a failed run rather than a clean one.
    public var wasCancelled = false
    /// Informational notes for stderr (e.g. the `--index-store` fallback
    /// message, or a one-line index summary). Never affects exit status.
    public var notes: [String] = []

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

    /// Set when every file the run was given was skipped — unreadable, not
    /// UTF-8, or over the size cap — so it analyzed nothing. A file whose
    /// analysis was only cut short does not count.
    public var everyFileSkipped: Bool {
        analyzedFileCount > 0
            && Set(degradedFiles.lazy.filter(\.skipped).map(\.path)).count >= analyzedFileCount
    }

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
        /// Whether the whole file went unanalyzed; false when only part of its
        /// analysis was skipped, such as one function over the statement bound.
        public let skipped: Bool

        public init(path: String, detail: String, skipped: Bool = true) {
            self.path = path
            self.detail = detail
            self.skipped = skipped
        }
    }
}
