//  Lifted from SwiftStaticAnalysis (MIT) — Models/SourceLocation.swift.

// MARK: - SourceLocation

/// A location within a source file (1-indexed line/column).
struct SourceLocation: Sendable, Hashable, Codable {
    /// The file path.
    let file: String

    /// Line number (1-indexed).
    let line: Int

    /// Column number (1-indexed).
    let column: Int

    /// Byte offset from start of file.
    let offset: Int

    init(file: String, line: Int, column: Int, offset: Int = 0) {
        self.file = file
        self.line = line
        self.column = column
        self.offset = offset
    }
}

// MARK: - SourceRange

/// A range of source code.
struct SourceRange: Sendable, Hashable, Codable {
    /// Start location.
    let start: SourceLocation

    /// End location.
    let end: SourceLocation

    init(start: SourceLocation, end: SourceLocation) {
        self.start = start
        self.end = end
    }
}
