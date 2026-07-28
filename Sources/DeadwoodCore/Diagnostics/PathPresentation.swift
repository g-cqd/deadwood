#if canImport(FoundationEssentials)
    internal import FoundationEssentials
#else
    internal import Foundation
#endif

extension AnalysisReport {
    /// Rewrites every reported path to be relative to `root`.
    ///
    /// Analysis works in absolute paths — that is the only spelling that
    /// identifies a file unambiguously (see `SourcePath`). But *reporting* in
    /// absolute paths makes the output machine-specific, and two things depend
    /// on it not being:
    ///
    /// - `Finding.fingerprint` hashes the path, so a baseline written on a
    ///   developer's machine matches nothing in CI. Measured on a real module,
    ///   analyzing the same code from a different directory moved every
    ///   fingerprint.
    /// - GitHub code scanning resolves SARIF `uri` values against the
    ///   repository root, so absolute paths produce findings that link nowhere.
    ///
    /// Paths outside `root` are left absolute rather than escaped into `../..`
    /// chains, which no consumer resolves usefully. Notes carry paths as free
    /// text, so the prefix is stripped there too — a relative report must never
    /// mix both spellings.
    public func relativized(to root: String) -> AnalysisReport {
        let canonical = SourcePath.canonical(root)
        let prefix = canonical.hasSuffix("/") ? canonical : canonical + "/"
        func strip(_ path: String) -> String {
            path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
        }
        func stripInText(_ text: String) -> String {
            text.replacing(prefix, with: "")
        }
        func relativize(_ finding: Finding) -> Finding {
            Finding(
                rule: finding.rule,
                severity: finding.severity,
                path: strip(finding.path),
                line: finding.line,
                column: finding.column,
                message: stripInText(finding.message),
                note: finding.note.map(stripInText),
                // An explicit --relative-to is an explicit anchor request, so it sets
                // the fingerprint spelling too; from the repository root it matches the
                // automatic anchor exactly.
                fingerprintPath: strip(finding.path)
            )
        }

        var copy = self
        copy.findings = findings.map(relativize)
        copy.outOfScope = outOfScope.map(relativize)
        copy.suppressed = suppressed.map {
            SuppressedFinding(finding: relativize($0.finding), reason: $0.reason)
        }
        copy.degradedFiles = degradedFiles.map {
            DegradedFile(path: strip($0.path), detail: $0.detail)
        }
        return copy
    }
}

extension AnalysisReport {
    /// Rewrites every finding's `fingerprintPath` to be relative to `root`.
    ///
    /// Applied once, in the analyzer, before anything reads a fingerprint — so
    /// baselines, SARIF and the report agree, and agree across machines.
    func fingerprintsAnchored(to root: String) -> AnalysisReport {
        func anchor(_ finding: Finding) -> Finding {
            Finding(
                rule: finding.rule,
                severity: finding.severity,
                path: finding.path,
                line: finding.line,
                column: finding.column,
                message: finding.message,
                note: finding.note,
                fingerprintPath: RepositoryRoot.relativize(finding.path, to: root)
            )
        }
        var copy = self
        copy.findings = findings.map(anchor)
        copy.outOfScope = outOfScope.map(anchor)
        copy.suppressed = suppressed.map {
            SuppressedFinding(finding: anchor($0.finding), reason: $0.reason)
        }
        return copy
    }
}
