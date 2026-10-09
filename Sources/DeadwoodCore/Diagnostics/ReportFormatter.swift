import ProjectModel

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

    /// The JSON report: the analysis report's fields plus the shared contract version.
    private struct VersionedReport: Encodable {
        let report: AnalysisReport
        private enum CodingKeys: String, CodingKey { case schemaVersion }
        func encode(to encoder: any Encoder) throws {
            try report.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(ReportSchema.version, forKey: .schemaVersion)
        }
    }

    private static func json(_ report: AnalysisReport) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(VersionedReport(report: report)),
            let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }

    // MARK: - SARIF 2.1.0

    private struct SarifLog: Encodable {
        enum CodingKeys: String, CodingKey {
            case version
            case schema = "$schema"
            case runs
        }

        let version = "2.1.0"
        let schema = "https://json.schemastore.org/sarif-2.1.0.json"
        let runs: [SarifRun]
    }

    private struct SarifRun: Encodable {
        let tool: SarifTool
        let invocations: [SarifInvocation]
        /// The absolute URI of ``ArtifactURI/baseID``, which relative uris
        /// resolve against (nil without a root — optionals are omitted).
        let originalUriBaseIds: [String: SarifArtifactLocation]?
        /// The unit every region's columns count in; see ``UTF16Columns``.
        let columnKind = "utf16CodeUnits"
        let results: [SarifResult]
    }

    private struct SarifTool: Encodable {
        let driver: SarifDriver
    }

    /// Whether the run produced a result a consumer may trust. A run that
    /// analyzed nothing carries an error notification, which SARIF defines as
    /// a failed run whose results are incomplete (SARIF 2.1.0 §3.20.21).
    private struct SarifInvocation: Encodable {
        let executionSuccessful: Bool
        let toolExecutionNotifications: [SarifNotification]?

        init(_ report: AnalysisReport) {
            let failure: String? =
                if report.wasCancelled {
                    "the run was cancelled before the corpus was complete; no findings reported"
                } else if report.everyFileSkipped {
                    "every file in the corpus was skipped (unreadable, non-UTF8, or over the size cap); "
                        + "nothing was analyzed"
                } else {
                    nil
                }
            executionSuccessful = failure == nil
            // A warning note names a requested feature that did not run, or a setup that degrades the
            // findings. It is reported as a warning and never fails the run.
            let warnings = report.notes.filter { $0.hasPrefix("\(ToolInfo.name): warning: ") }
            let notifications =
                (failure.map { [SarifNotification(level: "error", message: SarifText(text: $0))] } ?? [])
                + warnings.map { SarifNotification(level: "warning", message: SarifText(text: $0)) }
            toolExecutionNotifications = notifications.isEmpty ? nil : notifications
        }
    }

    private struct SarifNotification: Encodable {
        let level: String
        let message: SarifText
    }

    private struct SarifDriver: Encodable {
        let name: String
        let version: String
        let informationUri: String
        let rules: [SarifRuleDescriptor]
    }

    private struct SarifRuleDescriptor: Encodable {
        let id: String
        let shortDescription: SarifText
        let help: SarifText
    }

    private struct SarifText: Encodable {
        let text: String
    }

    private struct SarifResult: Encodable {
        let ruleId: String
        let level: String
        let message: SarifText
        let locations: [SarifLocation]
        let partialFingerprints: [String: String]
        /// Omitted (nil) when the finding has no confidence.
        let properties: SarifResultProperties?
    }

    private struct SarifResultProperties: Encodable {
        let confidence: String
    }

    private struct SarifLocation: Encodable {
        let physicalLocation: SarifPhysicalLocation
    }

    private struct SarifPhysicalLocation: Encodable {
        let artifactLocation: SarifArtifactLocation
        let region: SarifRegion
    }

    private struct SarifArtifactLocation: Encodable {
        let uri: String
        let uriBaseId: String?

        /// `path` as ``ArtifactURI`` writes it; see there for the two forms.
        init(path: String, root: String?) {
            (uri, uriBaseId) = ArtifactURI.location(of: path, root: root)
        }

        init(uri: String) {
            self.uri = uri
            uriBaseId = nil
        }
    }

    private struct SarifRegion: Encodable {
        let startLine: Int
        let startColumn: Int
    }

    /// - Parameter root: the canonical directory the report's relative paths
    ///   hang from, or nil when every path is absolute.
    private static func sarif(_ report: AnalysisReport, root: String?) -> String {
        var columns = UTF16Columns(root: root)
        let results = report.findings.map { finding in
            SarifResult(
                ruleId: finding.rule.rawValue,
                level: finding.severity.rawValue,
                message: SarifText(
                    text: finding.note.map { "\(finding.message) — \($0)" } ?? finding.message
                ),
                locations: [
                    SarifLocation(
                        physicalLocation: SarifPhysicalLocation(
                            artifactLocation: SarifArtifactLocation(path: finding.path, root: root),
                            region: SarifRegion(
                                startLine: finding.line,
                                startColumn: columns.column(finding.column, line: finding.line, path: finding.path)
                            )
                        )
                    )
                ],
                partialFingerprints: ["deadwood/v1": finding.fingerprint],
                properties: finding.confidence.map { SarifResultProperties(confidence: $0.rawValue) }
            )
        }
        // Degraded files were previously invisible in SARIF — the format the
        // GitHub action uploads — so unparseable or unreadable code looked
        // analyzed. A "note"-level result per degraded file keeps them on the
        // record where the findings live.
        let degradedResults = report.degradedFiles.map { file in
            SarifResult(
                ruleId: "deadwood/degraded-file",
                level: "note",
                message: SarifText(text: degradedText(file)),
                locations: [
                    SarifLocation(
                        physicalLocation: SarifPhysicalLocation(
                            artifactLocation: SarifArtifactLocation(path: file.path, root: root),
                            region: SarifRegion(startLine: 1, startColumn: 1)
                        )
                    )
                ],
                partialFingerprints: [:],
                properties: nil
            )
        }
        let log = SarifLog(runs: [
            SarifRun(
                tool: SarifTool(
                    driver: SarifDriver(
                        name: ToolInfo.name,
                        version: ToolInfo.version,
                        informationUri: ToolInfo.informationURI,
                        rules: RuleID.allCases.map {
                            SarifRuleDescriptor(
                                id: $0.rawValue,
                                shortDescription: SarifText(text: $0.summary),
                                help: SarifText(text: $0.explanation)
                            )
                        }
                    )),
                invocations: [SarifInvocation(report)],
                originalUriBaseIds: root.map {
                    [ArtifactURI.baseID: SarifArtifactLocation(uri: ArtifactURI.baseURI(of: $0))]
                },
                results: results + degradedResults
            )
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(log), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
