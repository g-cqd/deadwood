#if os(macOS)
    import Foundation
    import IndexStoreSupport
    import SourceCorpus
    import Testing

    @testable import DeadwoodCore

    /// The compiler records which member witnesses or overrides which requirement. When the requirement is defined outside
    /// the files analyzed, code outside them calls the member, whatever its name and wherever the conformance is written.
    /// The syntax can only go by a list of the requirements it knows.
    @Suite(.enabled(if: SwiftcIndexFixture.available, "needs swiftc"))
    struct IndexExternalWitnessTests {
        private static let main = """
            struct Bag {
                func makeIterator() -> IndexingIterator<[Int]> { [1, 2].makeIterator() }
                var underestimatedCount: Int { 2 }
                func unusedHelper() {}
            }

            @main
            struct App {
                static func main() {
                    for value in Bag() { print(value) }
                }
            }

            """

        /// The conformance is written apart from the type, in another file. The list of requirements deadwood knows for
        /// `Sequence` does not include `underestimatedCount`, a customization point the standard library calls.
        private static let conformance = """
            extension Bag: Sequence {}

            """

        private static func messages(production: Bool = false) async throws -> [String] {
            let root = FileManager.default.temporaryDirectory.appending(path: "deadwood-witness-\(UUID().uuidString)")
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let main = root.appending(path: "Main.swift")
            let other = root.appending(path: "Other.swift")
            try Self.main.write(to: main, atomically: true, encoding: .utf8)
            try conformance.write(to: other, atomically: true, encoding: .utf8)
            let store = root.appending(path: "store")
            try SwiftcIndexFixture.build(store: store, module: "App", files: [main, other], in: root)
            let options = IndexStoreOptions(
                enabled: true,
                explicitPath: store.path,
                cacheRoot: root.appending(path: "cache").path
            )
            return await Analyzer().analyze(files: [main.path, other.path], indexStore: options).findings.map(\.message)
        }

        @Test
        func
            `a member that witnesses a requirement of the SDK through a conformance written elsewhere is not reported`()
            async throws
        {
            let messages = try await Self.messages()
            #expect(!messages.contains { $0.contains("'underestimatedCount") }, "\(messages)")
        }

        @Test func `a member that witnesses nothing is still reported`() async throws {
            let messages = try await Self.messages()
            #expect(messages.contains { $0.contains("'unusedHelper") }, "\(messages)")
        }

        /// The mechanism itself, beside the end-to-end tests above, which the list of known requirements also satisfies: the
        /// graph names the member as a witness of a requirement that no analyzed file defines.
        @Test func `the graph names the members that witness a requirement outside the analyzed files`() async throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "deadwood-witness-\(UUID().uuidString)")
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let main = root.appending(path: "Main.swift")
            let other = root.appending(path: "Other.swift")
            try Self.main.write(to: main, atomically: true, encoding: .utf8)
            try Self.conformance.write(to: other, atomically: true, encoding: .utf8)
            let store = root.appending(path: "store")
            try SwiftcIndexFixture.build(store: store, module: "App", files: [main, other], in: root)
            let library = try #require(await ToolchainResolution.resolve().libraryPath)
            let files = [SourcePath.canonical(main.path), SourcePath.canonical(other.path)]
            guard
                case .usable(let session) = IndexStoreSession.open(
                    store.path,
                    cacheRoot: root.appending(path: "cache").path,
                    library: library,
                    analyzedFiles: files
                )
            else {
                Issue.record("the store did not open")
                return
            }
            let graph = IndexBasedDependencyGraph(analysisFiles: files)
            await graph.build(from: IndexStoreReader(session: session))
            let witnesses = graph.externalWitnessUSRs
            #expect(witnesses.contains { $0.contains("underestimatedCount") }, "\(witnesses)")
            #expect(!witnesses.contains { $0.contains("unusedHelper") }, "\(witnesses)")
        }
    }
#endif
