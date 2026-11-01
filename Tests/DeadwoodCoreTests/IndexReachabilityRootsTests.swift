#if os(macOS)
    import CorpusScan
    import Foundation
    import Testing

    @testable import DeadwoodCore

    /// What roots and what keeps a declaration alive on deadwood's index path: the graph's edges are the compiler's, so
    /// the code the compiler does not attribute to a declaration (a `#Preview` body) and the symbols that only describe
    /// a declaration (its parameters) must not decide what is reachable.
    @Suite(.enabled(if: SwiftcIndexFixture.available, "needs swiftc"))
    struct IndexReachabilityRootsTests {
        private static func directory() throws -> URL {
            let url = FileManager.default.temporaryDirectory.appending(path: "deadwood-roots-\(UUID().uuidString)")
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        private static func options(_ store: URL, _ root: URL) -> IndexStoreOptions {
            IndexStoreOptions(enabled: true, explicitPath: store.path, cacheRoot: root.appending(path: "cache").path)
        }

        /// Builds `source` as module `App` with an index, then analyzes it through that index.
        private static func report(_ source: String, defines: [String] = []) async throws -> AnalysisReport {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appending(path: "Sources/App/App.swift")
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try source.write(to: file, atomically: true, encoding: .utf8)
            let store = root.appending(path: "store")
            try SwiftcIndexFixture.build(
                store: store,
                module: "App",
                files: [file],
                in: root,
                extraArguments: defines.flatMap { ["-D", $0] }
            )
            return await Analyzer().analyze(files: [file.path], indexStore: options(store, root))
        }

        private static let entry = """
            @main
            struct App {
                static func main() {
                    run()
                }
            }

            func run() {
                print(1)
            }

            """

        /// A parameter is indexed as a child of its function. That child edge keeps a type alive through a member, but a
        /// parameter is not a member: a function nothing calls stays dead whatever it takes.
        @Test func `a function with a parameter that nothing calls is reported`() async throws {
            let report = try await Self.report(
                Self.entry + """
                    func deadWithParameter(_ value: Int) -> Int {
                        value + 1
                    }

                    """
            )
            let messages = report.findings.map(\.message)
            #expect(messages.contains { $0.contains("deadWithParameter") }, "\(messages)")
        }

        @Test func `a type whose only user is its own initializer's parameters is reported`() async throws {
            let report = try await Self.report(
                Self.entry + """
                    final class DeadModel {
                        let identifier: Int

                        init(identifier: Int) {
                            self.identifier = identifier
                        }
                    }

                    """
            )
            let messages = report.findings.map(\.message)
            #expect(messages.contains { $0.contains("DeadModel") }, "\(messages)")
        }

        @Test func `a function that is called is still kept alive by its caller`() async throws {
            let report = try await Self.report(
                """
                @main
                struct App {
                    static func main() {
                        caller()
                    }
                }

                func caller() {
                    _ = callee(1)
                }

                func callee(_ value: Int) -> Int {
                    value
                }

                """
            )
            let messages = report.findings.map(\.message)
            #expect(!messages.contains { $0.contains("callee") }, "\(messages)")
        }

        /// A `#Preview` body expands to code the compiler does not attribute to any declaration of the corpus, so the
        /// index draws no edge from it. What it names is named by code that runs in the preview, which roots it.
        @Test func `a declaration used only by a preview is not reported as unused`() async throws {
            let report = try await Self.report(
                """
                import SwiftUI

                struct Row: View {
                    let user: Int
                    var body: some View { Text("\\(user)") }
                }

                @main
                struct App {
                    static func main() {
                        _ = Row(user: 1)
                    }
                }

                #if DEBUG
                    #Preview {
                        Row(user: sampleUser)
                    }

                    private let sampleUser = 0
                #endif

                """,
                defines: ["DEBUG"]
            )
            let messages = report.findings.map(\.message)
            #expect(!messages.contains { $0.contains("sampleUser") }, "\(messages)")
        }

        /// Production code that only previews use is `preview-only`, once: the index run must not also call it unused.
        @Test func `code only a preview uses is reported once as preview-only`() async throws {
            let report = try await Self.report(
                """
                import SwiftUI

                struct Row: View {
                    let user: Int
                    var body: some View { Text("\\(user)") }
                }

                func sampleRow() -> Row {
                    Row(user: 3)
                }

                @main
                struct App {
                    static func main() {
                        _ = Row(user: 1)
                    }
                }

                #if DEBUG
                    #Preview {
                        sampleRow()
                    }
                #endif

                """,
                defines: ["DEBUG"]
            )
            let about = report.findings.filter { $0.message.contains("sampleRow") }
            #expect(about.map(\.rule) == [.previewOnly], "\(about.map { "\($0.rule) \($0.message)" })")
        }
    }
#endif
