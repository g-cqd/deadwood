/// A single diagnostic produced by a rule.
public struct Finding: Sendable, Equatable {
    public let rule: RuleID
    public let severity: Severity
    public let path: String
    public let line: Int
    public let column: Int
    public let message: String
    /// Optional secondary context (retention path, doc citation, fix hint).
    public let note: String?

    public init(
        rule: RuleID,
        severity: Severity,
        path: String,
        line: Int,
        column: Int,
        message: String,
        note: String? = nil
    ) {
        self.rule = rule
        self.severity = severity
        self.path = path
        self.line = line
        self.column = column
        self.message = message
        self.note = note
    }
}

extension Finding: Comparable {
    /// Deterministic report ordering: path, then position, then rule.
    public static func < (lhs: Finding, rhs: Finding) -> Bool {
        if lhs.path != rhs.path { return lhs.path < rhs.path }
        if lhs.line != rhs.line { return lhs.line < rhs.line }
        if lhs.column != rhs.column { return lhs.column < rhs.column }
        return lhs.rule.rawValue < rhs.rule.rawValue
    }
}

extension Finding: Codable {
    private enum CodingKeys: String, CodingKey {
        case rule, severity, path, line, column, message, note, fingerprint
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            rule: try container.decode(RuleID.self, forKey: .rule),
            severity: try container.decode(Severity.self, forKey: .severity),
            path: try container.decode(String.self, forKey: .path),
            line: try container.decode(Int.self, forKey: .line),
            column: try container.decode(Int.self, forKey: .column),
            message: try container.decode(String.self, forKey: .message),
            note: try container.decodeIfPresent(String.self, forKey: .note)
        )
        // fingerprint is derived — ignored on decode, recomputed on access.
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rule, forKey: .rule)
        try container.encode(severity, forKey: .severity)
        try container.encode(path, forKey: .path)
        try container.encode(line, forKey: .line)
        try container.encode(column, forKey: .column)
        try container.encode(message, forKey: .message)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encode(fingerprint, forKey: .fingerprint)
    }
}
