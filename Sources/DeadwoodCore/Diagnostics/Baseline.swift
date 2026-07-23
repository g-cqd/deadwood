import Foundation

/// A set of accepted finding fingerprints — pre-existing debt a team adopts
/// the tool against without a wall of noise. Baselined findings are filtered
/// out of the report (and the exit code), but their count stays visible.
///
/// Fingerprints include line/column, so unrelated edits above a finding shift
/// it out of the baseline — regenerate with `--write-baseline` after big
/// moves. That is the deliberate trade against fuzzy matching silently
/// swallowing *new* bugs.
public struct Baseline: Sendable, Equatable {
    public let fingerprints: Set<String>

    public init(fingerprints: Set<String>) {
        self.fingerprints = fingerprints
    }

    public init(findings: [Finding]) {
        self.init(fingerprints: Set(findings.map(\.fingerprint)))
    }

    public func contains(_ finding: Finding) -> Bool {
        fingerprints.contains(finding.fingerprint)
    }

    /// Splits findings into (kept, baselined).
    public func filter(_ findings: [Finding]) -> (kept: [Finding], baselined: [Finding]) {
        var kept: [Finding] = []
        var baselined: [Finding] = []
        for finding in findings {
            if contains(finding) {
                baselined.append(finding)
            } else {
                kept.append(finding)
            }
        }
        return (kept, baselined)
    }

    // MARK: - Persistence (versioned JSON, deterministic ordering)

    private struct Payload: Codable {
        var version: Int
        var tool: String
        var fingerprints: [String]
    }

    public static func load(path: String) throws(DeadwoodError) -> Baseline {
        let data = try BoundedFileReader.read(path: path)
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw .configurationInvalid(path: path, detail: String(describing: error))
        }
        guard payload.version == 1 else {
            throw .configurationInvalid(path: path, detail: "unsupported baseline version \(payload.version)")
        }
        return Baseline(fingerprints: Set(payload.fingerprints))
    }

    public func write(path: String) throws(DeadwoodError) {
        let payload = Payload(
            version: 1,
            tool: ToolInfo.name,
            fingerprints: fingerprints.sorted()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(payload)
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            throw .configurationUnreadable(path: path, underlying: String(describing: error))
        }
    }
}

extension Finding {
    /// Stable identity for baselines and SARIF `partialFingerprints`.
    /// FNV-1a 64-bit over the finding's identifying fields — identity hashing,
    /// not security; collisions merely over-baseline one finding.
    public var fingerprint: String {
        let hash = FNV1a.hash("\(rule.rawValue)|\(path)|\(line)|\(column)|\(message)")
        return String(hash, radix: 16, uppercase: false)
    }
}
