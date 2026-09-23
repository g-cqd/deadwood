/// How a SARIF log names the file a location points at.
///
/// A SARIF `uri` is an RFC 3986 URI reference (SARIF 2.1.0 §3.10.1), and a
/// relative one is resolved against the base its `uriBaseId` names (§3.4.4).
/// A filesystem path is neither: `/Users/me/My Repo/A.swift` holds a space no
/// URI may, a `#` in a file name starts a fragment, so `Box#1.swift` reads as
/// `Box` — and a relative path with no base resolves against whatever the
/// reader guesses.
///
/// So a location takes one of two forms, the convention arcleak and dolly
/// share:
///
/// - Relative to the `--relative-to` directory, with `uriBaseId` naming that
///   directory, when the file lies inside it and its relative path is made
///   only of characters a URI carries unescaped. That is nearly every path.
/// - Otherwise an absolute `file://` URI, percent-encoded as UTF-8.
///
/// A relative path is never percent-encoded, deliberately. Some readers take a
/// relative reference as a plain path, and would look for `My%20Dir/A.swift`
/// and find nothing; every reader decodes an absolute `file://` URI, so the
/// few paths that need escapes take that form instead.
enum ArtifactURI {
    /// The `uriBaseId` that relative locations name, and the key under which
    /// `run.originalUriBaseIds` gives its absolute URI.
    static let baseID = "SRCROOT"

    /// The `uri` and `uriBaseId` for `path` as a report spells it: relative to
    /// `root` once the report was relativized to it, or absolute.
    /// - Parameter root: the canonical directory the report's relative paths
    ///   hang from; nil when the report was not relativized.
    static func location(of path: String, root: String?) -> (uri: String, uriBaseId: String?) {
        if path.hasPrefix("/") {
            return (fileURI(path), nil)
        }
        if path.utf8.allSatisfy(isUnescaped) {
            return (path, root == nil ? nil : baseID)
        }
        guard let root else {
            // No directory to anchor it to: an escaped relative reference is still a
            // valid one.
            return (percentEncoded(path), nil)
        }
        return (fileURI(root.hasSuffix("/") ? root + path : root + "/" + path), nil)
    }

    /// `directory` as the absolute URI `originalUriBaseIds` gives for
    /// ``baseID``, which must end in a slash (SARIF 2.1.0 §3.14.14).
    static func baseURI(of directory: String) -> String {
        let uri = fileURI(directory)
        return uri.hasSuffix("/") ? uri : uri + "/"
    }

    /// `file://` and the percent-encoded absolute `path`; with no host, as SARIF
    /// 2.1.0 §3.10.2 recommends for a local file (`file:///…`).
    static func fileURI(_ path: String) -> String {
        "file://" + percentEncoded(path)
    }

    /// `path` with every UTF-8 byte outside the unescaped set written as `%XX`,
    /// in the upper-case hexadecimal RFC 3986 normalizes to.
    /// - Complexity: O(*n*) in the UTF-8 length of `path`.
    static func percentEncoded(_ path: String) -> String {
        var encoded = ""
        encoded.reserveCapacity(path.utf8.count)
        for byte in path.utf8 {
            if isUnescaped(byte) {
                encoded.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                let hex = String(byte, radix: 16, uppercase: true)
                encoded += byte < 0x10 ? "%0" + hex : "%" + hex
            }
        }
        return encoded
    }

    /// RFC 3986's unreserved characters, its sub-delimiters less `;`, `@`, and
    /// `/` as the separator: what a path carries unescaped in every reader. `:`
    /// is left out because in a relative reference's first segment it reads as a
    /// scheme; `;` because older URL parsers split parameters on it.
    private static let unescapedBytes = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,=@/".utf8)

    private static func isUnescaped(_ byte: UInt8) -> Bool {
        unescapedBytes.contains(byte)
    }
}
