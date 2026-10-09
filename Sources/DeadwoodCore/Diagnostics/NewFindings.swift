/// Promotes the findings a `--only` scope hid when they are new relative to a baseline.
///
/// In a pull request, `--only` reports the changed files. A change that removes the last use of a
/// declaration in an unchanged file leaves that declaration dead, and the scope hides it. Promoting
/// each out-of-scope finding whose fingerprint the base branch's baseline does not hold reports
/// the dead code the change created, and leaves the debt that was already there out of scope.
public enum NewFindings {
    /// Moves each finding in ``AnalysisReport/outOfScope`` whose fingerprint is not in `fingerprints`
    /// into ``AnalysisReport/findings``, and keeps the rest out of scope.
    ///
    /// Suppressed and excluded findings are never in ``AnalysisReport/outOfScope``, so they are
    /// never promoted. ``AnalysisReport/findings`` is re-sorted after the move.
    /// - Parameter fingerprints: the fingerprints of the baseline written on the base branch.
    /// - Returns: the report, and the fingerprints of the findings that were promoted.
    /// - Complexity: O(*n* log *n*) for *n* findings, from the sort.
    public static func promote(
        _ report: AnalysisReport, notIn fingerprints: Set<String>
    ) -> (report: AnalysisReport, promoted: Set<String>) {
        var copy = report
        var promoted: Set<String> = []
        var outOfScope: [Finding] = []
        for finding in report.outOfScope {
            let fingerprint = finding.fingerprint
            if fingerprints.contains(fingerprint) {
                outOfScope.append(finding)
            } else {
                copy.findings.append(finding)
                promoted.insert(fingerprint)
            }
        }
        copy.outOfScope = outOfScope
        copy.findings.sort()
        return (copy, promoted)
    }
}
