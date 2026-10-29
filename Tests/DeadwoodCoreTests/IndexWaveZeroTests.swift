#if canImport(IndexStoreDB)
    import Foundation
    import Testing

    @testable import DeadwoodCore

    /// The `libIndexStore.dylib` trust policy is arcleak's (root or the current user, never writable by others), and a
    /// path that is not an index store is refused without writing into it (analyzerkit roadmap 0035, probes D4, D1).
    @Suite struct IndexWaveZeroTests {
        private static func directory() throws -> URL {
            let url = FileManager.default.temporaryDirectory.appending(path: "deadwood-wave0-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url.resolvingSymlinksInPath()
        }

        @Test func `a dylib owned by the current user and writable by no one else is trusted`() throws {
            let directory = try Self.directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let dylib = directory.appending(path: "libIndexStore.dylib")
            try Data([0]).write(to: dylib)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dylib.path)
            // An Xcode.app installed outside the App Store, and every swiftly toolchain, is owned by its user.
            #expect(BinaryTrustChecker.isTrusted(at: dylib.path))
        }

        @Test func `a writable dylib and directory are refused while a link follows the target policy`() throws {
            let directory = try Self.directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let writable = directory.appending(path: "group.dylib")
            try Data([0]).write(to: writable)
            try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: writable.path)
            let trusted = directory.appending(path: "trusted.dylib")
            try Data([0]).write(to: trusted)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: trusted.path)
            let link = directory.appending(path: "link.dylib")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: trusted)
            #expect(!BinaryTrustChecker.isTrusted(at: writable.path))
            #expect(BinaryTrustChecker.isTrusted(at: link.path))
            #expect(!BinaryTrustChecker.isTrusted(at: directory.path))
        }

        @Test func `a path that is not an index store is refused, and nothing is created in it`() async throws {
            let directory = try Self.directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let given = directory.appending(path: "DerivedData")
            try FileManager.default.createDirectory(at: given, withIntermediateDirectories: true)
            let outcome = await IndexStoreFallbackManager(configuration: FallbackConfiguration(autoBuild: false))
                .resolveIndexStore(projectRoot: directory.path, sourceFiles: [], explicitPath: given.path)
            guard case .fallback(let reason) = outcome else {
                Issue.record("opened \(given.path) as an index store")
                return
            }
            #expect(reason.description.contains("not an index store"), "\(reason.description)")
            let created =
                try FileManager.default.contentsOfDirectory(atPath: given.path)
                + FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0 != "DerivedData" }
            #expect(created.isEmpty, "created \(created)")
        }
    }
#endif
