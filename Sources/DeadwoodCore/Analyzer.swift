import Foundation
import SwiftParser
import SwiftSyntax

/// Entry point of the pipeline: reads each file with a bounded reader, scans
/// suppression directives, runs the rule set, and assembles the report.
/// The detection engine lands behind this interface; the pipeline, directive,
/// baseline, and reporting contracts are stable.
public struct Analyzer: Sendable {
    /// Files above this cap are reported degraded rather than read into RAM.
    public static let sourceByteCap = 10 * 1024 * 1024

    public let configuration: Configuration

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    public func analyze(files: [String]) async -> AnalysisReport {
        var report = AnalysisReport()
        for path in files {
            if Task.isCancelled { break }
            report.analyzedFileCount += 1
            let data: Data
            do {
                data = try BoundedFileReader.read(path: path, cap: Self.sourceByteCap)
            } catch {
                report.degradedFiles.append(
                    .init(path: path, detail: "read failed or exceeds size cap: \(error)")
                )
                continue
            }
            let source = String(decoding: data, as: UTF8.self)
            merge(analyze(source: source, path: path), into: &report)
        }
        report.findings.sort()
        return report
    }

    public func analyze(source: String, path: String) -> AnalysisReport {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        let directives = DirectiveScanner.scan(tree: tree, converter: converter)
        let table = SuppressionTable(directives: directives)

        // Rules run here once the engine lands; the suppression plumbing is
        // exercised from day one so directives never regress.
        let raw: [Finding] = []

        var report = AnalysisReport()
        report.analyzedFileCount = 1
        for finding in raw {
            if let reason = table.suppression(for: finding.rule, line: finding.line) {
                report.suppressed.append(.init(finding: finding, reason: reason))
            } else {
                report.findings.append(finding)
            }
        }
        report.findings.sort()
        return report
    }

    private func merge(_ partial: AnalysisReport, into report: inout AnalysisReport) {
        report.findings.append(contentsOf: partial.findings)
        report.suppressed.append(contentsOf: partial.suppressed)
        report.degradedFiles.append(contentsOf: partial.degradedFiles)
    }
}
