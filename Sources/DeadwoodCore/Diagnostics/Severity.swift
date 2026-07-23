/// Diagnostic severity, ordered so the maximum over a report decides the exit code.
public enum Severity: String, Comparable, Sendable, Codable {
    case warning
    case error

    public static func < (lhs: Severity, rhs: Severity) -> Bool {
        lhs == .warning && rhs == .error
    }
}
