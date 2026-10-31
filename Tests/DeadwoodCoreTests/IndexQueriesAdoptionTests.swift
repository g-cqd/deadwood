#if os(macOS)
    @testable import DeadwoodCore
    import Foundation
    import IndexStoreSupport
    import SourceCorpus
    import Testing

    /// deadwood reads the store through analyzerkit's `IndexQueries` (roadmap 0054): occurrences come back in the corpus's
    /// spelling, so a store that records `/private/var/…` for a `/var/…` corpus answers in `/var/…`.
    @Suite(.enabled(if: SwiftcIndexFixture.available, "needs swiftc"))
    struct IndexQueriesAdoptionTests {
        @Test func `occurrences carry the corpus's spelling of their file`() async throws {
            // Not resolved through links: swiftc is given `/var/folders/…` and the store records `/private/var/…`.
            let directory = FileManager.default.temporaryDirectory.appending(path: "deadwood-iq-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appending(path: "A.swift")
            try "public func entry() { used() }\nfunc used() {}\n".write(to: file, atomically: true, encoding: .utf8)
            let store = directory.appending(path: "store")
            try SwiftcIndexFixture.build(store: store, module: "A", files: [file], in: directory)
            let library = try #require(await ToolchainResolution.resolve().libraryPath)
            let canonical = SourcePath.canonical(file.path)
            guard
                case .usable(let session) = IndexStoreSession.open(
                    store.path, cacheRoot: directory.appending(path: "cache").path, library: library,
                    analyzedFiles: [canonical])
            else {
                Issue.record("the store did not open")
                return
            }
            let reader = IndexStoreReader(session: session)
            let files = reader.allOccurrencesByUSR(in: [canonical]).values.flatMap { $0.map(\.file) }
            #expect(!files.isEmpty && files.allSatisfy { $0 == canonical }, "\(Set(files))")
            let used = try #require(
                reader.allOccurrencesByUSR(in: [canonical]).first { $0.value.contains { $0.symbol.name == "used()" } })
            #expect(reader.findOccurrences(ofUSR: used.key).allSatisfy { $0.file == canonical })
        }
    }
#endif
