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
            let device = number(attributes[.systemNumber]),
            let inode = number(attributes[.systemFileNumber]),
            let size = number(attributes[.size]),
            let modified = attributes[.modificationDate] as? Date
        else { return nil }

        // FNV-1a hashes file identity, not executable contents. The delimiter
        // keeps neighboring fields from producing an ambiguous byte sequence.
        let fields = [
            resolved, String(device), String(inode), String(size), String(modified.timeIntervalSince1970),
        ]
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in fields.joined(separator: "\0").utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// Foundation boxes file attributes as `NSNumber` on Darwin, and as `UInt` or
    /// `UInt64` in FoundationEssentials, which has no `NSNumber` on Linux.
    private static func number(_ value: Any?) -> UInt64? {
        switch value {
        case let number as UInt64: number
        case let number as UInt: UInt64(number)
        case let number as Int: UInt64(exactly: number)
        default: nil
        }
    }

    private static var executablePath: String? {
        #if os(Linux)
            try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")
        #else
            Bundle.main.executablePath
        #endif
    }
}
