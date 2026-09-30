import AemiJSON

// MARK: - TokenLine

/// An identifier-shaped token found in a string literal, with its line.
@JSONCodable
struct TokenLine: Sendable, Hashable, Codable {
    let token: String
    let line: Int

    init(token: String, line: Int) {
        self.token = token
        self.line = line
    }
}
