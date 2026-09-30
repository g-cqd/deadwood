/// The kinds of code that do not ship as ordinary production logic. A piece
/// of code can belong to several at once: a `#Preview` inside `#if DEBUG` is
/// both `preview` and `debugOnly`. The empty set is production code.
public struct CodeRegion: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Production code: no region flag set.
    public static let production: CodeRegion = []

    /// Compiled only in debug builds (`#if DEBUG`).
    public static let debugOnly = CodeRegion(rawValue: 1 << 0)

    /// A SwiftUI preview: `#Preview` or a `PreviewProvider`.
    public static let preview = CodeRegion(rawValue: 1 << 1)

    /// Test code.
    public static let test = CodeRegion(rawValue: 1 << 2)

    /// A test double.
    public static let mock = CodeRegion(rawValue: 1 << 3)

    /// Written by a generator, not by hand.
    public static let generated = CodeRegion(rawValue: 1 << 4)

    /// Top-level statements, which run when the file is executed.
    public static let script = CodeRegion(rawValue: 1 << 5)
}
