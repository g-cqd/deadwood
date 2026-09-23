#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Converts deadwood's columns to the unit SARIF regions count in.
///
/// Findings carry swift-syntax's columns: 1-based UTF-8 byte offsets into the
/// line. They stay that way everywhere else — the fingerprint hashes them, and
/// compilers print byte columns too — but a SARIF run declares its
/// `columnKind`, and the one consumers assume is `utf16CodeUnits` (SARIF 2.1.0
/// §3.14.27), the unit editors index lines in.
/// On a line with non-ASCII text before a finding, a byte column lands to the
/// right of it: after `"😀é"` it is three columns off. arcleak and dolly
/// convert the same way.
///
/// A byte-order mark does not count (SARIF 2.1.0 §3.30.2). deadwood hands
/// swift-syntax the file's text with its mark, so the byte columns of line 1
/// count it and the conversion takes it out; arcleak's decode drops the mark
/// before parsing instead.
///
/// Each file is read once, capped like the analyzer's own reads. A file that
/// can no longer be read keeps its byte column, which is exact whenever the
/// text before it is ASCII.
struct UTF16Columns {
    /// A file's bytes, and the offset each of its lines starts at.
    private struct Text {
        let bytes: [UInt8]
        let lineStarts: [Int]
    }

    /// Where relative report paths resolve; nil when every path is absolute.
    private let root: String?
    /// Each file read so far, or nil when it could not be.
    private var texts: [String: Text?] = [:]

    init(root: String?) {
        self.root = root
    }

    /// `column`, a UTF-8 column on `line` of `path`, in UTF-16 code units.
    /// - Complexity: O(*c*) in the column, after one O(*n*) read of the file.
    mutating func column(_ column: Int, line: Int, path: String) -> Int {
        guard column > 1, line >= 1, let text = text(of: path), line <= text.lineStarts.count else {
            return column
        }
        let start = text.lineStarts[line - 1]
        let lineEnd = line < text.lineStarts.count ? text.lineStarts[line] : text.bytes.count
        let end = start + column - 1
        guard end <= lineEnd else { return column }
        var before = text.bytes[start..<end]
        if start == 0, before.starts(with: Self.byteOrderMark) {
            before = before.dropFirst(Self.byteOrderMark.count)
        }
        return String(decoding: before, as: UTF8.self).utf16.count + 1
    }

    /// The UTF-8 byte-order mark.
    private static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

    private mutating func text(of path: String) -> Text? {
        if let cached = texts[path] { return cached }
        let resolved: String
        if path.hasPrefix("/") {
            resolved = path
        } else if let root {
            resolved = root.hasSuffix("/") ? root + path : root + "/" + path
        } else {
            resolved = path
        }
        let text = (try? BoundedFileReader.read(path: resolved, cap: Analyzer.sourceByteCap)).map {
            let bytes = [UInt8]($0)
            return Text(bytes: bytes, lineStarts: Self.lineStarts(of: bytes))
        }
        texts[path] = text
        return text
    }

    /// Where each line starts, breaking lines where swift-syntax does: at `\n`,
    /// `\r\n` and a lone `\r`. Line 1 starts at the first byte, where
    /// swift-syntax starts it, byte-order mark included.
    private static func lineStarts(of bytes: [UInt8]) -> [Int] {
        var starts = [0]
        var index = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "\r"), index + 1 < bytes.count,
                bytes[index + 1] == UInt8(ascii: "\n")
            {
                index += 1
            }
            if bytes[index] == UInt8(ascii: "\n") || bytes[index] == UInt8(ascii: "\r") {
                starts.append(index + 1)
            }
            index += 1
        }
        return starts
    }
}
