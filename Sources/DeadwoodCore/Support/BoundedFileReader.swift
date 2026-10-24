import SourceCorpus

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Reads a small configuration-class file with a stat-first size cap, so a hostile or accidental giant JSON
/// can't be pulled into RAM. Fails closed with a typed error. The read is analyzerkit's; this maps its two
/// failures onto this tool's errors.
enum BoundedFileReader {
    /// 1 MB is generous for config/baseline JSON and cheap to reject above.
    static let configByteCap = SourceCorpus.BoundedFileReader.configByteCap

    static func read(
        path: String,
        cap: Int = configByteCap
    ) throws(DeadwoodError) -> Data {
        do {
            return try SourceCorpus.BoundedFileReader.readConfiguration(path: path, cap: cap)
        } catch {
            if let detail = error.invalidDetail { throw .configurationInvalid(path: path, detail: detail) }
            guard case .unreadable(let underlying) = error else {
                throw .configurationInvalid(path: path, detail: "\(error)")
            }
            throw .configurationUnreadable(path: path, underlying: underlying)
        }
    }
}
