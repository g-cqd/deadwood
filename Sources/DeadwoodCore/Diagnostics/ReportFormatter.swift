import ProjectModel
import ReportSupport
import SourceCorpus

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public enum OutputFormat: String, CaseIterable, Sendable {
    /// `path:line:col: warning|error: [rule] message — note` — parsed by Xcode
    /// and SwiftPM build logs into inline diagnostics.
    case xcode
    /// Stable, versioned JSON of the full report.
    case json
    /// SARIF 2.1.0 — GitHub code scanning and other SARIF consumers.
    case sarif
}

public enum ReportFormatter {
    /// - Parameter root: the directory `report` was relativized to, if any.
    ///   SARIF declares it as the base its relative uris resolve against.
    public static func format(
        _ report: AnalysisReport, as format: OutputFormat, relativeTo root: String? = nil
    ) -> String {
        switch format {
        case .xcode: xcode(report)
        case .json: json(report)
        case .sarif: sarif(report, root: root.map(SourcePath.canonical))
        }
    }

    /// One human summary line (for stderr, so stdout stays machine-parseable).
    public static func summary(_ report: AnalysisReport) -> String {
        let errors = report.findings.count(where: { $0.severity == .error })
        let notes = report.findings.count(where: { $0.severity == .note })
        let warnings = report.findings.count - errors - notes
        var line = "\(ToolInfo.name): \(report.findings.count) finding(s) "
        line += "(\(errors) error(s), \(warnings) warning(s)"
        line += notes > 0 ? ", \(notes) note(s))" : ")"
        line += " in \(report.analyzedFileCount) file(s)"
        line += ReportSummary.notChecked(Set(report.degradedFiles.map(\.path)).count)
        if !report.suppressed.isEmpty {
            line += "; \(report.suppressed.count) suppressed"
        }
        if !report.degradedFiles.isEmpty {
            line += "; \(Set(report.degradedFiles.map(\.path)).count) file(s) degraded"
        }
        return line
    }

    private static func xcode(_ report: AnalysisReport) -> String {
        var lines: [String] = []
        for finding in report.findings {
            var text = "\(finding.path):\(finding.line):\(finding.column): "
            text += "\(finding.severity.rawValue): [\(finding.rule.rawValue)] \(finding.message)"
            if let note = finding.note {
                text += " — \(note)"
            }
            lines.append(text)
        }
        for degraded in report.degradedFiles {
            lines.append("\(degraded.path):1:1: warning: [deadwood] \(degradedText(degraded))")
        }
        return lines.joined(separator: "\n")
    }

    /// What a degraded-file note says: that the file was skipped, or that part
    /// of its analysis was, and why.
    private static func degradedText(_ file: AnalysisReport.DegradedFile) -> String {
        (file.skipped ? "file skipped: " : "analysis degraded: ") + file.detail
    }

    /// The JSON report: the analysis report's fields and the keys every analyzer's report carries (ADR-0017).
    private static func envelope(_ report: AnalysisReport) -> ReportEnvelope<AnalysisReport> {
        var seen: Set<String> = []
        let skipped = report.degradedFiles.compactMap { file in
            seen.insert(file.path).inserted ? SkippedFile(path: file.path, reason: .degraded) : nil
        }
        return ReportEnvelope(
            report, tool: ToolInfo.name, version: ToolInfo.version, runNotes: report.notes.map(runNote),
            skippedFiles: skipped)
    }

    /// A free-text note as a run note: deadwood's `notes` stay as they are, and are listed here too (ADR-0017).
    private static func runNote(_ note: String) -> RunNote {
        RunNote(
            code: "general", severity: note.hasPrefix("\(ToolInfo.name): warning: ") ? "warning" : "note", message: note
        )
    }

    private static func json(_ report: AnalysisReport) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(envelope(report)),
            let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }

    // MARK: - SARIF 2.1.0

    /// The SARIF log, on analyzerkit's shared model.
    /// - Parameter root: the canonical directory the report's relative paths hang from, or nil when every path is absolute.
    private static func sarif(_ report: AnalysisReport, root: String?) -> String {
        var columns = SarifColumns(root: root, byteOrderMark: .parsed, readCap: Analyzer.sourceByteCap)
        /// Where a finding or a related location points, its column in UTF-16.
        func location(_ path: String, line: Int, column: Int, message: Sarif.Text? = nil) -> Sarif.Location {
            Sarif.Location(
                physicalLocation: Sarif.PhysicalLocation(
                    artifactLocation: Sarif.ArtifactLocation(path: path, root: root),
                    region: Sarif.Region(startLine: line, startColumn: columns.column(column, line: line, path: path))),
                message: message)
        }
        let results = report.findings.map { finding in
            Sarif.Result(
                ruleId: finding.rule.rawValue,
                level: finding.severity.rawValue,
                message: Sarif.Text(finding.note.map { "\(finding.message) — \($0)" } ?? finding.message),
                locations: [location(finding.path, line: finding.line, column: finding.column)],
                partialFingerprints: ["deadwood/v1": finding.fingerprint],
                properties: finding.confidence.map { ["confidence": .string($0.rawValue)] }
            )
        }
        // Degraded files were invisible in SARIF, the format code scanning uploads, so unparseable or unreadable code
        // looked analyzed. A note-level result per degraded file keeps them where the findings are.
        let degradedResults = report.degradedFiles.map { file in
            Sarif.Result(
                ruleId: "deadwood/degraded-file",
                level: "note",
                message: Sarif.Text(degradedText(file)),
                locations: [
                    Sarif.Location(
                        physicalLocation: Sarif.PhysicalLocation(
                            artifactLocation: Sarif.ArtifactLocation(path: file.path, root: root),
                            region: Sarif.Region(startLine: 1, startColumn: 1)))
                ],
                partialFingerprints: [:]
            )
        }
        // A run that analyzed nothing fails: its results are incomplete (SARIF 2.1.0 §3.20.21).
        let failure: String? =
            if report.wasCancelled {
                "the run was cancelled before the corpus was complete; no findings reported"
            } else if report.everyFileSkipped {
                "every file in the corpus was skipped (unreadable, non-UTF8, or over the size cap); "
                    + "nothing was analyzed"
            } else {
                nil
            }

        // A warning note names a requested feature that did not run, or a setup that degrades the findings. It is reported as
        // a warning and never fails the run.
        let warnings = report.notes.filter { $0.hasPrefix("\(ToolInfo.name): warning: ") }
        let driver = Sarif.Driver(
            name: ToolInfo.name,
            version: ToolInfo.version,
            informationUri: ToolInfo.informationURI,
            rules: RuleID.allCases.map {
                Sarif.Rule(
                    id: $0.rawValue, shortDescription: Sarif.Text($0.summary), help: Sarif.Text($0.explanation))
            })
        let log = Sarif.Log(runs: [
            Sarif.Run(
                tool: Sarif.Tool(driver: driver), invocations: [Sarif.Invocation(failure: failure, warnings: warnings)],
                root: root,
                results: results + degradedResults)
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(log), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
