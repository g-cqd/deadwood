#if os(macOS)
    import Foundation
    import Testing

    @testable import DeadwoodCore

    /// A build that skips function bodies (Xcode's "prepare for indexing" does) leaves an index with the declarations and
    /// their signatures, and no use inside any body. What a body names is then absent from the index, not unused.
    @Suite(.enabled(if: SwiftcIndexFixture.available, "needs swiftc"))
    struct IndexUnindexedBodyTests {
        private static let source = """
            struct Model {
                let label = "a"
                func run() {
                    helper()
                    print(label)
                }
                private func helper() {
                    print(Self.spacing)
                }
                static var spacing: Int { 8 }
                func neverCalled() {
                    print("x")
                }
            }

            @main
            struct App {
                static func main() {
                    Model().run()
                }
            }

            """

        private static func messages(of source: String = source, extraArguments: [String]) async throws -> [String] {
            let root = FileManager.default.temporaryDirectory.appending(path: "deadwood-bodies-\(UUID().uuidString)")
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appending(path: "App.swift")
            try source.write(to: file, atomically: true, encoding: .utf8)
            let store = root.appending(path: "store")
            try SwiftcIndexFixture.build(
                store: store,
                module: "App",
                files: [file],
                in: root,
                extraArguments: extraArguments
            )
            let options = IndexStoreOptions(
                enabled: true,
                explicitPath: store.path,
                cacheRoot: root.appending(path: "cache").path
            )
            return await Analyzer().analyze(files: [file.path], indexStore: options).findings.map(\.message)
        }

        /// The index says nothing of what the bodies use, so no verdict is drawn from it about what they name. Nothing
        /// names `neverCalled`, in the source or in the index, and it is still reported.
        private static func notes(extraArguments: [String]) async throws -> [String] {
            let root = FileManager.default.temporaryDirectory.appending(path: "deadwood-bodies-\(UUID().uuidString)")
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appending(path: "App.swift")
            try Self.source.write(to: file, atomically: true, encoding: .utf8)
            let store = root.appending(path: "store")
            try SwiftcIndexFixture.build(
                store: store,
                module: "App",
                files: [file],
                in: root,
                extraArguments: extraArguments
            )
            let options = IndexStoreOptions(
                enabled: true,
                explicitPath: store.path,
                cacheRoot: root.appending(path: "cache").path
            )
            return await Analyzer().analyze(files: [file.path], indexStore: options).notes
        }

        /// The index says nothing of what the bodies use, so no verdict is drawn from it about what they name. Nothing
        /// names `neverCalled`, in the source or in the index, and it is still reported.

        /// The report says how many declarations needed uses the index lacks, so a partial store can be told from a complete one.
        @Test func `the index note counts the declarations whose uses it lacks`() async throws {
            let partial = try await Self.notes(extraArguments: Self.skipBodies)
            #expect(partial.contains { $0.contains("with uses the index lacks") }, "\(partial)")
            let complete = try await Self.notes(extraArguments: [])
            #expect(!complete.contains { $0.contains("with uses the index lacks") }, "\(complete)")
        }

        @Test func `what the bodies of a declarations-only index name is not reported`() async throws {
            let messages = try await Self.messages(extraArguments: [
                "-Xfrontend", "-experimental-skip-all-function-bodies",
            ])
            #expect(messages.count == 1 && messages[0].contains("'neverCalled"), "\(messages)")
        }

        /// With the bodies indexed the index decides, and `neverCalled` is the one thing nothing uses.
        @Test func `the same code is judged by the index when the bodies are indexed`() async throws {
            let messages = try await Self.messages(extraArguments: [])
            #expect(messages.count == 1 && messages[0].contains("'neverCalled"), "\(messages)")
        }

        private static let skipBodies = ["-Xfrontend", "-experimental-skip-all-function-bodies"]

        /// Two types have a `value`. Only `A`'s is used, by a bare name inside `A`, and a build that skipped the bodies does
        /// not say so. The name stands for the member of the type it is written in, not for every `value` of the corpus, so
        /// `B`, with its `value`, is still reported.
        @Test func `a bare name in a body that was not indexed stands for the member in scope`() async throws {
            let messages = try await Self.messages(
                of: """
                    struct A {
                        var value: Int { 1 }
                        func total() -> Int {
                            value + 1
                        }
                    }

                    struct B {
                        var value: Int { 2 }
                    }

                    @main
                    struct App {
                        static func main() {
                            print(A().total())
                        }
                    }

                    """,
                extraArguments: Self.skipBodies
            )
            // `B` is the one nothing uses, and with it its `value`; `A.value` is not named by the finding.
            #expect(messages.count == 1 && messages[0].contains("'B'") && !messages[0].contains("'A'"), "\(messages)")
        }

        /// A type built inside an autoclosure (`StateObject(wrappedValue: Model(...))`): the index of a build that skipped the
        /// bodies has neither the call nor the initializer's own uses, and the member the initializer reads is still used.
        @Test func `a type built in a body that was not indexed is built, and what its initializer reads is used`()
            async throws
        {
            let messages = try await Self.messages(
                of: """
                    final class Model {
                        private let provider: Int
                        init(provider: Int) {
                            self.provider = provider
                            print(self.provider)
                        }
                    }

                    struct Holder {
                        let model: Model
                        init(provider: Int) {
                            model = Model(provider: provider)
                        }
                    }

                    @main
                    struct App {
                        static func main() {
                            print(Holder(provider: 1).model)
                        }
                    }

                    """,
                extraArguments: Self.skipBodies
            )
            #expect(messages.isEmpty, "\(messages)")
        }
    }
#endif
