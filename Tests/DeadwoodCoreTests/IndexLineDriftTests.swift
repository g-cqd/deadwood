#if os(macOS)
    import Foundation
    import Testing

    @testable import DeadwoodCore

    /// A store describes a file as one build saw it. The source it is read against can have moved since (lines inserted),
    /// and a store keeps the units of every build that wrote to it, so it can describe the file at several lines at
    /// once. Neither may leave a declaration that is used looking dead: a declaration whose line no symbol matches maps
    /// to nothing, and the walk starts from symbols.
    @Suite(.enabled(if: SwiftcIndexFixture.available, "needs swiftc"))
    struct IndexLineDriftTests {
        private static let padding = String(repeating: "\n", count: 12)

        /// `Box.used` is read only by `App.main`, the entry point. Two types declare `main`, so the name alone does not
        /// say which symbol `App.main` is. `padded` puts the lines between the two, moving `App` and not `Box`.
        private static func source(padded: Bool) -> String {
            """
            struct Box {
                let used = 1
                let unused = 2
            }

            struct Other {
                static func main() {}
            }
            \(padded ? padding : "")
            @main
            struct App {
                static func main() {
                    print(Box().used)
                }
            }

            """
        }

        private static func directory() throws -> URL {
            let url = FileManager.default.temporaryDirectory.appending(path: "deadwood-drift-\(UUID().uuidString)")
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        private static func build(_ source: String, file: URL, store: URL, in root: URL) throws {
            try source.write(to: file, atomically: true, encoding: .utf8)
            try SwiftcIndexFixture.build(store: store, module: "App", files: [file], in: root)
        }

        private static func messages(file: URL, store: URL, root: URL) async -> [String] {
            let options = IndexStoreOptions(
                enabled: true,
                explicitPath: store.path,
                cacheRoot: root.appending(path: "cache").path
            )
            return await Analyzer().analyze(files: [file.path], indexStore: options).findings.map(\.message)
        }

        /// The store was built from the file before lines were inserted, and the file's date is that of the build, so
        /// the store is not taken for stale. Only `Box.unused` is dead.
        @Test func `a file whose lines moved since the build keeps what its entry point uses`() async throws {
            let root = try Self.directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appending(path: "App.swift")
            let store = root.appending(path: "store")
            try Self.build(Self.source(padded: false), file: file, store: store, in: root)
            let built = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date

            try Self.source(padded: true).write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: built ?? .distantPast], ofItemAtPath: file.path)

            let messages = await Self.messages(file: file, store: store, root: root)
            #expect(!messages.contains { $0.contains("'used'") || $0.contains("Box") }, "\(messages)")
        }

        /// A second build into the same store, after lines were inserted, leaves the units of the first beside its own.
        /// The symbols are at their new lines in one of them.
        @Test func `a store that keeps the units of an earlier build maps to the lines of the current file`()
            async throws
        {
            let root = try Self.directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appending(path: "App.swift")
            let store = root.appending(path: "store")
            try Self.build(Self.source(padded: false), file: file, store: store, in: root)
            try Self.build(Self.source(padded: true), file: file, store: store, in: root)

            let messages = await Self.messages(file: file, store: store, root: root)
            #expect(!messages.contains { $0.contains("'used'") || $0.contains("Box") }, "\(messages)")
        }

        /// Rooting by name must not hide what is dead: nothing reads `unused`.
        @Test func `a property nothing reads is still reported when the lines moved`() async throws {
            let root = try Self.directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appending(path: "App.swift")
            let store = root.appending(path: "store")
            try Self.build(Self.source(padded: true), file: file, store: store, in: root)

            let messages = await Self.messages(file: file, store: store, root: root)
            #expect(messages.contains { $0.contains("'unused'") }, "\(messages)")
        }
    }
#endif
