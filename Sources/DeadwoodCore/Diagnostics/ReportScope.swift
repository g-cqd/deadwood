/// The set of files a report is narrowed to — typically a pull request's
/// changed files.
///
/// Scoping applies to the *report*, never to the corpus. Reachability is a
/// corpus-level property: a declaration looks unused precisely when nothing
/// references it, so shrinking the corpus to the changed files turns every
/// cross-file reference into a false positive. Measured on a 16-file pull
/// request against a 2603-file codebase, the whole-corpus run reported no dead
/// code in those files while a changed-files-only run reported six — all of
/// them wrong. So the engine keeps seeing everything and this filters what
/// comes out.
///
/// Findings carry a single location, so membership is a plain containment
/// check; there is no clone-group anchor problem here.
public struct ReportScope: Sendable, Equatable {
    /// Canonical absolute paths, matching `Finding.path`.
    public let files: Set<String>

    public var isEmpty: Bool { files.isEmpty }

    /// Paths are canonicalized on the way in, so callers can pass whatever
    /// `git diff --name-only` produced without worrying about spelling.
    public init(files: some Sequence<String>) {
        self.files = Set(files.lazy.map(SourcePath.canonical))
    }

    public func contains(_ finding: Finding) -> Bool {
        files.contains(finding.path)
    }

    /// Splits findings into (inScope, outOfScope), mirroring `Baseline.filter`.
    public func filter(_ findings: [Finding]) -> (inScope: [Finding], outOfScope: [Finding]) {
        let (outOfScope, inScope) = findings.partitioned(by: contains)
        return (inScope, outOfScope)
    }
}
