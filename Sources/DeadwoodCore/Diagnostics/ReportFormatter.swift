import ProjectModel
public import ReportSupport

public typealias OutputFormat = ReportOutputFormat

/// deadwood's reports in the shared formats; the renderers are analyzerkit's `ToolReportFormat`.
public enum ReportFormatter: ToolReportFormat {
    public typealias Report = AnalysisReport

    public static let toolName = ToolInfo.name
    public static let toolVersion = ToolInfo.version
    public static let informationURI = ToolInfo.informationURI
    public static let byteOrderMark = SarifColumns.ByteOrderMark.parsed
    public static let readCap = Analyzer.sourceByteCap

    public static var sarifRules: [Sarif.Rule] {
        RuleID.allCases.map {
            Sarif.Rule(
                id: $0.rawValue,
                shortDescription: Sarif.Text($0.summary),
                help: Sarif.Text($0.explanation)
            )
        }
    }
}

extension Finding: ReportedFinding {
    public var severityName: String { severity.rawValue }
    public var ruleName: String { rule.rawValue }
    public var displayMessage: String { note.map { "\(message) — \($0)" } ?? message }
    public var sarifProperties: [String: Sarif.Property]? {
        confidence.map { ["confidence": .string($0.rawValue)] }
    }
}

extension AnalysisReport.DegradedFile: ReportedDegradedFile {
    /// What a degraded-file note says: that the file was skipped, or that part of its analysis was, and why.
    public var displayText: String { (skipped ? "file skipped: " : "analysis degraded: ") + detail }
    public var skippedWhole: Bool { skipped }
}

extension AnalysisReport: ToolReport {
    public var suppressedCount: Int { suppressed.count }

    /// deadwood's `notes` stay as they are, and are listed as run notes too (ADR-0017).
    public var trailingRunNotes: [RunNote] {
        notes.map {
            RunNote(
                code: "general",
                severity: $0.hasPrefix("\(ToolInfo.name): warning: ") ? "warning" : "note",
                message: $0
            )
        }
    }

    /// A warning note names a requested feature that did not run, or a setup that degrades the findings. It is reported
    /// as a warning and never fails the run.
    public var sarifWarnings: [String] { notes.filter { $0.hasPrefix("\(ToolInfo.name): warning: ") } }
}
