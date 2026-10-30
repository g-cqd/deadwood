#if os(macOS)
    import Foundation
    import Testing

    /// Index stores built by the `swiftc` `xcrun` selects, which matches the `libIndexStore.dylib` analyzerkit's
    /// resolution picks. `-emit-module` matters: a `-typecheck` build records no per-file units.
    enum SwiftcIndexFixture {
        static let swiftc: String? = {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["--find", "swiftc"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let swiftc = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return process.terminationStatus == 0 && FileManager.default.isExecutableFile(atPath: swiftc) ? swiftc : nil
        }()

        static var available: Bool { swiftc != nil }

        /// Compiles `files` as module `module`, recording the index into `store`.
        static func build(store: URL, module: String, files: [URL], in directory: URL) throws {
            guard let swiftc else { throw CocoaError(.featureUnsupported) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: swiftc)
            process.arguments =
                [
                    "-index-store-path", store.path, "-index-ignore-system-modules", "-module-name", module,
                    "-parse-as-library", "-emit-module",
                    "-emit-module-path", directory.appendingPathComponent("\(module).swiftmodule").path,
                ] + files.map(\.path)
            process.currentDirectoryURL = directory
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
        }
    }

    /// deadwood opens index stores through analyzerkit's `IndexStoreSession` and finds them with `IndexStoreLocation`
    /// (analyzerkit roadmap 0019 step B, ADR-0004): the database lives under the cache root, never beside the store, and
    /// a store is found wherever a build puts one.
    @Suite(.enabled(if: SwiftcIndexFixture.available, "needs swiftc"))
    struct IndexStoreSessionAdoptionTests {
        /// A package of one module whose store is built at `store` (relative to the package).
        private static func package(storeAt store: String) throws -> URL {
            let root = FileManager.default.temporaryDirectory.appending(path: "deadwood-session-\(UUID().uuidString)")
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"A\")\n".write(
                to: root.appending(path: "Package.swift"), atomically: true, encoding: .utf8)
            let sources = root.appending(path: "Sources/A")
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            let file = sources.appending(path: "A.swift")
            try "public func entry() { used() }\nfunc used() {}\nfunc unused() {}\n".write(
                to: file, atomically: true, encoding: .utf8)
            let storeURL = root.appending(path: store)
            try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
            try SwiftcIndexFixture.build(store: storeURL, module: "A", files: [file], in: root)
            return root
        }

        @Test func `the index database lives under the cache root, not beside the store`() throws {
            let root = try Self.package(storeAt: "store")
            defer { try? FileManager.default.removeItem(at: root) }
            let cache = root.appending(path: "cache")
            let run = try BuiltTool.run(
                [
                    "analyze", "Sources", "--index-store-path", root.appending(path: "store").path, "--cache-path",
                    cache.path,
                ], in: root)

            #expect(run.standardError.contains("--index-store active"), "\(run.standardError)")
            #expect(!FileManager.default.fileExists(atPath: root.appending(path: "IndexDatabase").path))
            let databases = (try? FileManager.default.contentsOfDirectory(atPath: cache.appending(path: "index").path))
            #expect(databases?.count == 1, "\(databases ?? [])")
        }

        /// Given a SwiftPM build configuration, the store is the `index/store` below it.
        @Test func `a build directory given as the store resolves to the store below it`() throws {
            let root = try Self.package(storeAt: "build/debug/index/store")
            defer { try? FileManager.default.removeItem(at: root) }
            let run = try BuiltTool.run(
                [
                    "analyze", "Sources", "--index-store-path", root.appending(path: "build/debug").path,
                    "--cache-path", root.appending(path: "cache").path,
                ], in: root)

            #expect(run.standardError.contains("--index-store active"), "\(run.standardError)")
            #expect(String(decoding: run.standardOutput, as: UTF8.self).contains("unused()"))
        }

        /// SwiftPM puts each configuration under its target triple; `.build/debug` is only a link to it.
        @Test func `discovery finds a store under a target triple`() throws {
            let root = try Self.package(storeAt: ".build/arm64-apple-macosx/debug/index/store")
            defer { try? FileManager.default.removeItem(at: root) }
            let run = try BuiltTool.run(
                ["analyze", "Sources", "--index-store", "--cache-path", root.appending(path: "cache").path], in: root)

            #expect(run.standardError.contains("--index-store active"), "\(run.standardError)")
        }
    }
#endif
