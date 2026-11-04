#if os(macOS)
    import Foundation
    import Testing

    @testable import DeadwoodCore

    /// A unit that could not resolve a type of a member's signature (a module it imports is missing from the build) records
    /// the member with an error type in its USR, and a call from a unit that could resolve it records the resolved USR. The
    /// two never match, so the member would look uncalled. They share the module, the types and the name, and that links them.
    /// One compiler run cannot produce units that disagree, so the end-to-end tests below guard the common case, and the
    /// shapes of the two USRs are tested directly.
    @Suite(.enabled(if: SwiftcIndexFixture.available, "needs swiftc"))
    struct IndexUnresolvedTypeTests {
        private static let login = """
            import MissingDependency

            final class Login {
                init(domain: String, provider: Provider) {
                    print(domain, provider)
                }

                func start(provider: Provider, email: String) {
                    print(provider, email)
                }

                func neverStarted(provider: Provider) {
                    print(provider)
                }
            }

            """

        private static let entry = """
            @main
            struct App {
                static func main() {
                    let login = Login(domain: "a", provider: .init())
                    login.start(provider: .init(), email: "a")
                }
            }

            """

        private static func messages() async throws -> [String] {
            let root = FileManager.default.temporaryDirectory.appending(path: "deadwood-xe-\(UUID().uuidString)")
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let login = root.appending(path: "Login.swift")
            let entry = root.appending(path: "Entry.swift")
            try Self.login.write(to: login, atomically: true, encoding: .utf8)
            try Self.entry.write(to: entry, atomically: true, encoding: .utf8)
            let store = root.appending(path: "store")
            try SwiftcIndexFixture.build(
                store: store,
                module: "App",
                files: [login, entry],
                in: root,
                extraArguments: ["-Xfrontend", "-experimental-allow-module-with-compiler-errors"],
                allowingCompilerErrors: true
            )
            let options = IndexStoreOptions(
                enabled: true,
                explicitPath: store.path,
                cacheRoot: root.appending(path: "cache").path
            )
            return await Analyzer().analyze(files: [login.path, entry.path], indexStore: options).findings.map(
                \.message
            )
        }

        @Test func `the prefix of an unresolved definition is the one its resolved call shares`() {
            let definition = "s:3App5LoginC5startyXeXeF"
            let call = "s:3App5LoginC5start8provider5emailySS_tF"
            let prefix = IndexBasedDependencyGraph.memberPrefix(of: definition, named: "start")
            #expect(prefix == "s:3App5LoginC5start")
            #expect(call.hasPrefix(prefix ?? "?"))
            // A member of another type, or another name, does not share it.
            #expect(!"s:3App5OtherC5start8provider5emailySS_tF".hasPrefix(prefix ?? "?"))
            #expect(!"s:3App5LoginC6starts8provider5emailySS_tF".hasPrefix(prefix ?? "?"))
            #expect(IndexBasedDependencyGraph.memberPrefix(of: definition, named: "stop") == nil)
            // A private member keeps its discriminator after the name, which the prefix leaves out.
            #expect(
                IndexBasedDependencyGraph.memberPrefix(of: "s:3App5LoginC6secret33_ABCDEFLLyXeXeF", named: "secret")
                    == "s:3App5LoginC6secret"
            )
        }

        @Test func `a member called from another unit is called, whatever its signature failed to resolve`()
            async throws
        {
            let messages = try await Self.messages()
            #expect(!messages.contains { $0.contains("'start") || $0.contains("'Login'") }, "\(messages)")
        }

        @Test func `a member nothing calls is still reported`() async throws {
            let messages = try await Self.messages()
            #expect(messages.contains { $0.contains("'neverStarted") }, "\(messages)")
        }
    }
#endif
