import Foundation

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
    public static func format(_ report: AnalysisReport, as format: OutputFormat) -> String {
        switch format {
        case .xcode: xcode(report)
        case .json: json(report)
        case .sarif: sarif(report)
        }
    }

    /// One human summary line (for stderr, so stdout stays machine-parseable).
    public static func summary(_ report: AnalysisReport) -> String {
        let errors = report.findings.count(where: { $0.severity == .error })
        let warnings = report.findings.count - errors
        var line = "\(ToolInfo.name): \(report.findings.count) finding(s) "
        line += "(\(errors) error(s), \(warnings) warning(s)) in \(report.analyzedFileCount) file(s)"
        if !report.suppressed.isEmpty {
            line += "; \(report.suppressed.count) suppressed"
        }
        if !report.degradedFiles.isEmpty {
            line += "; \(report.degradedFiles.count) file(s) degraded"
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
            lines.append("\(degraded.path):1:1: warning: [deadwood] file skipped: \(degraded.detail)")
        }
        return lines.joined(separator: "\n")
    }

    private static func json(_ report: AnalysisReport) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report), let text = String(data: data, encoding: .utf8) else {
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
        let results: [SarifResult]
    }

    private struct SarifTool: Encodable {
        let driver: SarifDriver
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
    }

    private struct SarifRegion: Encodable {
        let startLine: Int
        let startColumn: Int
    }

    private static func sarif(_ report: AnalysisReport) -> String {
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
                            artifactLocation: SarifArtifactLocation(uri: finding.path),
                            region: SarifRegion(
                                startLine: finding.line,
                                startColumn: finding.column
                            )
                        )
                    )
                ],
                partialFingerprints: ["deadwood/v1": finding.fingerprint]
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
                results: results
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
