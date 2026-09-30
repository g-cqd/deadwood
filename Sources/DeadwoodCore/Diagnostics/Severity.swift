/// Diagnostic severity, ordered so the maximum over a report decides the exit code.
public enum Severity: String, Comparable, Sendable, Codable {
    /// Information: never fails a run, not even under `--strict`.
    case note
    case warning
    case error

    public static func < (lhs: Severity, rhs: Severity) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .note: 0
        case .warning: 1
        case .error: 2
        }
    }
}
