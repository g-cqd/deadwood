#if os(macOS)
    import CorpusScan
    import Foundation
    import Testing

    @testable import DeadwoodCore

    /// deadwood's index path (analyzerkit roadmap 0024): references from files the index does not cover count by name
    /// (D2), the advice follows the coverage class, the store opens once and each file is queried once, and the graph
    /// build scales with the corpus.
    @Suite(.enabled(if: SwiftcIndexFixture.available, "needs swiftc"))
    struct IndexCoveragePathTests {
        private static func directory() throws -> URL {
            let url = FileManager.default.temporaryDirectory.appending(path: "deadwood-cov-\(UUID().uuidString)")
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        private static func write(_ text: String, _ url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        private static func options(_ store: URL, _ root: URL) -> IndexStoreOptions {
            IndexStoreOptions(enabled: true, explicitPath: store.path, cacheRoot: root.appending(path: "cache").path)
        }

        private static let app = """
            @main
            struct App {
                static func main() {
                    run()
                }
            }

            func run() {
                print(1)
            }

            func helper() -> Int {
                42
            }

            func reallyDead() -> Int {
                0
            }

            """

        /// D2: `helper()` is used only by a test file the index never saw. Its reference counts, by name.
        @Test func `a reference from a file the index does not cover keeps its target alive`() async throws {
            let root = try Self.directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let app = root.appending(path: "Sources/App/App.swift")
            try Self.write(Self.app, app)
            let store = root.appending(path: "store")
            try SwiftcIndexFixture.build(store: store, module: "App", files: [app], in: root)
            let test = root.appending(path: "Tests/AppTests/HelperTests.swift")
            try Self.write(
                "import Testing\n@testable import App\n\n@Test func usesHelper() {\n    #expect(helper() == 42)\n}\n",
                test)

            let report = await Analyzer().analyze(files: [app.path, test.path], indexStore: Self.options(store, root))
            let messages = report.findings.map(\.message)
            #expect(messages.contains { $0.contains("reallyDead") }, "\(messages)")
            #expect(!messages.contains { $0.contains("helper") }, "\(messages)")
            // The advice follows the class: a file with no unit was not built by this scheme.
            #expect(report.notes.contains { $0.contains("not built by this scheme") }, "\(report.notes)")
        }

        /// One store open per run, and one occurrence query per analyzed file.
        @Test func `the store opens once and each file is queried once`() async throws {
            let root = try Self.directory()
            defer { try? FileManager.default.removeItem(at: root) }
            var files: [URL] = []
            for index in 0..<4 {
                let file = root.appending(path: "Sources/App/File\(index).swift")
                try Self.write("func f\(index)() -> Int { \(index) }\n", file)
                files.append(file)
            }
            let main = root.appending(path: "Sources/App/main.swift")
            try Self.write("print(f0() + f1())\n", main)
            files.append(main)
            let store = root.appending(path: "store")
            try SwiftcIndexFixture.build(store: store, module: "App", files: files, in: root)

            let counter = IndexQueryCounter()
            let report = await IndexQueryCounter.$current.withValue(counter) {
                await Analyzer().analyze(files: files.map(\.path), indexStore: Self.options(store, root))
            }
            #expect(report.notes.contains { $0.contains("--index-store active") }, "\(report.notes)")
            #expect(counter.storeOpens == 1)
            #expect(counter.occurrenceQueries == files.count)
        }

        /// The graph build grows with the corpus, not with its square: eight times the files take far less than
        /// sixty-four times as long.
        @Test func `the graph build scales with the corpus`() async throws {
            let root = try Self.directory()
            defer { try? FileManager.default.removeItem(at: root) }
            func corpus(_ count: Int, _ name: String) throws -> (store: URL, files: [String]) {
                var files: [URL] = []
                for index in 0..<count {
                    let file = root.appending(path: "\(name)/F\(index).swift")
                    let next = (index + 1) % count
                    try Self.write(
                        "struct T\(index) {\n    var value = \(index)\n    func call() -> Int { T\(next)().value + value }\n}\n",
                        file)
                    files.append(file)
                }
                let store = root.appending(path: "\(name)-store")
                try SwiftcIndexFixture.build(store: store, module: name, files: files, in: root)
                return (store, files.map(\.path))
            }
            func buildTime(_ corpus: (store: URL, files: [String])) async throws -> Duration {
                let outcome = await IndexStoreFallbackManager().resolveIndexStore(
                    projectRoot: root.path, sourceFiles: corpus.files, explicitPath: corpus.store.path,
                    cacheRoot: root.appending(path: "cache").path)
                guard case .index(let reader, _) = outcome else { throw CocoaError(.fileReadUnknown) }
                let graph = IndexBasedDependencyGraph(analysisFiles: corpus.files)
                let clock = ContinuousClock()
                let started = clock.now
                await graph.build(from: reader)
                return clock.now - started
            }
            let small = try await buildTime(corpus(50, "Small"))
            let large = try await buildTime(corpus(400, "Large"))
            #expect(large < small * 24, "50 files: \(small), 400 files: \(large)")
        }
    }
#endif
