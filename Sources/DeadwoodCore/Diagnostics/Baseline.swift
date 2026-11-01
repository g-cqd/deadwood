public import ReportSupport

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A set of accepted finding fingerprints — pre-existing debt a team adopts
/// the tool against without a wall of noise. Baselined findings are filtered
/// out of the report (and the exit code), but their count stays visible.
///
/// Fingerprints include line/column, so unrelated edits above a finding shift
/// it out of the baseline — regenerate with `--write-baseline` after big
/// moves. That is the deliberate trade against fuzzy matching silently
/// swallowing *new* bugs.
public typealias Baseline = FindingBaseline<Finding>

extension Finding: Fingerprinted {}

extension FindingBaseline where Finding == DeadwoodCore.Finding {
    // MARK: - Persistence (versioned JSON, deterministic ordering)

    public static func load(path: String) throws(DeadwoodError) -> Self {
        let data = try BoundedFileReader.read(path: path)
        do {
            return try Self(decoding: data)
        } catch {
            throw .configurationInvalid(path: path, detail: error.description)
        }
    }

    public func write(path: String) throws(DeadwoodError) {
        do {
            try encoded(tool: ToolInfo.name).write(to: URL(fileURLWithPath: path))
        } catch {
            throw .configurationUnreadable(path: path, underlying: String(describing: error))
        }
    }
}

extension Finding {
    /// Stable identity for baselines and SARIF `partialFingerprints`.
    public var fingerprint: String {
        Fingerprint.make(
            rule: rule.rawValue,
            path: fingerprintPath ?? path,
            line: line,
            column: column,
            message: message
        )
    }
}
