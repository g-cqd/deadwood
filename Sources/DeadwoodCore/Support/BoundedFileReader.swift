#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Reads a small configuration-class file with a stat-first size cap, so a
/// hostile or accidental giant JSON can't be pulled into RAM. Fails closed
/// with a typed error.
enum BoundedFileReader {
    /// 1 MB is generous for config/baseline JSON and cheap to reject above.
    static let configByteCap = 1 * 1024 * 1024

    static func read(
        path: String,
        cap: Int = configByteCap
    ) throws(DeadwoodError) -> Data {
        let url = URL(fileURLWithPath: path)
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        guard (attributes?[.type] as? FileAttributeType) == .typeRegular else {
            throw .configurationUnreadable(path: path, underlying: "not a regular file")
        }
        if let size = attributes?[.size] as? Int, size > cap {
            throw .configurationInvalid(path: path, detail: "exceeds \(cap) byte cap")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw .configurationUnreadable(path: path, underlying: String(describing: error))
        }
        guard data.count <= cap else {
            throw .configurationInvalid(path: path, detail: "exceeds \(cap) byte cap")
        }
        return data
    }
}
