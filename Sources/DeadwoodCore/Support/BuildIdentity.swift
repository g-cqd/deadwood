#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Identifies the executable whose extraction code produced cached facts.
enum BuildIdentity {
    static let current = identity(ofExecutableAt: executablePath)

    static func identity(ofExecutableAt path: String?) -> String? {
        guard let path else { return nil }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved),
            let device = attributes[.systemNumber] as? NSNumber,
            let inode = attributes[.systemFileNumber] as? NSNumber,
            let size = attributes[.size] as? NSNumber,
            let modified = attributes[.modificationDate] as? Date
        else { return nil }

        // FNV-1a hashes file identity, not executable contents. The delimiter
        // keeps neighboring fields from producing an ambiguous byte sequence.
        let fields = [
            resolved, device.stringValue, inode.stringValue, size.stringValue, String(modified.timeIntervalSince1970),
        ]
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in fields.joined(separator: "\0").utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    private static var executablePath: String? {
        #if os(Linux)
            try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")
        #else
            Bundle.main.executablePath
        #endif
    }
}
