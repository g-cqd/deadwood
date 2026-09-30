//  End-to-end proof that `--index-store` resolves references the name-level
//  syntax graph conflates. A two-file fixture defines `shared()` on two
//  different types; only `Alpha.shared` is called. deadwood's syntax graph
//  resolves the call `a.shared()` to BOTH same-named methods (over-connection),
//  so it flags neither. The index resolves it to `Alpha.shared`'s USR alone,
//  leaving `Beta.shared` provably dead — so the index finding set contains the
//  extra, correct finding.
//
//  Requires a real index, which requires `libIndexStore.dylib` + a matching
//  `swift` toolchain. Gated with `.enabled(if:)` on that tooling, and
//  soft-skips (early return with a printed reason) if the build/read fails in
//  the CI environment — mirroring how a macOS-only oracle test is gated.

#if canImport(IndexStoreDB)
    import Foundation
    import Testing

    @testable import DeadwoodCore

    // MARK: - Toolchain discovery

    enum IndexTestToolchain {
        /// The trusted `libIndexStore.dylib`, if any.
        static let dylib: String? = IndexStoreReader.findLibIndexStore()

        /// The `swift` binary in the SAME toolchain as `dylib`, so the index we
        /// build is readable by the dylib we open it with.
        static let swiftPath: String? = {
            guard let dylib else { return nil }
            let candidate = dylib.replacingOccurrences(
                of: "/lib/libIndexStore.dylib", with: "/bin/swift")
            return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
        }()

        /// Whether an index can be built and read in this environment.
        static var isAvailable: Bool { dylib != nil && swiftPath != nil }
    }

    // MARK: - Fixture builder

    struct IndexDeltaFixture {
        let root: URL
        let shapesFile: String
        let entryFile: String

        static func create() throws -> IndexDeltaFixture {
            let root = FileManager.default.temporaryDirectory
                .appending(path: "dw-idx-delta-\(UUID().uuidString)")
            var completed = false
            defer {
                if !completed { try? FileManager.default.removeItem(at: root) }
            }
            let sources = root.appending(path: "Sources/IndexDeltaFixture")
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)

            try """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(
                name: "IndexDeltaFixture",
                targets: [.executableTarget(name: "IndexDeltaFixture")]
            )
            """.write(to: root.appending(path: "Package.swift"), atomically: true, encoding: .utf8)

            // Two same-named methods in different types — the case the syntax
            // graph conflates.
            let shapes = sources.appending(path: "Shapes.swift")
            try """
            struct Alpha {
                func shared() {}
            }

            struct Beta {
                func shared() {}
            }
            """.write(to: shapes, atomically: true, encoding: .utf8)

            // Only Alpha.shared is ever called; Beta is constructed but its
            // `shared()` is dead.
            let entry = sources.appending(path: "Entry.swift")
            try """
            @main
            struct Entry {
                static func main() {
                    let a = Alpha()
                    a.shared()
                    _ = Beta()
                }
            }
            """.write(to: entry, atomically: true, encoding: .utf8)

            completed = true
            return IndexDeltaFixture(
                root: root, shapesFile: shapes.path, entryFile: entry.path)
        }

        var sourceFiles: [String] { [shapesFile, entryFile] }

        /// Build the package (SwiftPM enables index-while-building by default),
        /// using the toolchain that owns the reader dylib so the index is
        /// readable. Returns the discovered store path on success.
        func buildIndex(swiftPath: String) async -> String? {
            do {
                let result = try await ProcessExecutor.run(
                    executable: URL(fileURLWithPath: swiftPath),
                    arguments: ["build"],
                    currentDirectory: root,
                    timeout: .seconds(300)
                )
                guard result.succeeded else { return nil }
                return IndexStorePathFinder.findIndexStorePath(in: root.path)
            } catch {
                return nil
            }
        }
    }

    // MARK: - Test

    @Suite struct IndexReachabilityDeltaTests {
        private func sharedMethodFindings(_ report: AnalysisReport) -> [Finding] {
            report.findings.filter {
                $0.path.hasSuffix("Shapes.swift") && $0.message.contains("shared")
            }
        }

        @Test(
            "Index mode flags the dead same-named method the syntax graph conflates",
            // Local-only: builds a real index via a nested `swift build`, and the
            // IndexStoreDB dependency already dominates the macOS CI compile
            // budget. The fake-index unit suites cover the mapping/reachability
            // logic on CI; this end-to-end proof runs locally before release.
            .enabled(
                if: IndexTestToolchain.isAvailable
                    && ProcessInfo.processInfo.environment["CI"] == nil)
        )
        func indexResolvesSameNamedSymbolsSyntaxConflates() async throws {
            guard let swiftPath = IndexTestToolchain.swiftPath else { return }

            let fixture = try IndexDeltaFixture.create()
            defer { try? FileManager.default.removeItem(at: fixture.root) }

            guard let storePath = await fixture.buildIndex(swiftPath: swiftPath) else {
                print("IndexReachabilityDeltaTests: swift build did not produce a readable index; skipping")
                return
            }

            // Confirm the index is actually readable in this environment before
            // asserting on it (guards cross-toolchain read issues).
            let canonicalShapes = IndexBasedDependencyGraph.canonicalPath(fixture.shapesFile)
            guard
                let reader = try? IndexStoreReader(
                    indexStorePath: storePath, allowsDirectoryCreation: true),
                !reader.rawOccurrences(inFile: canonicalShapes).isEmpty
            else {
                print("IndexReachabilityDeltaTests: index opened empty (toolchain mismatch); skipping")
                return
            }

            let syntax = await Analyzer().analyze(files: fixture.sourceFiles)
            let index = await Analyzer().analyze(
                files: fixture.sourceFiles,
                indexStore: IndexStoreOptions(enabled: true, explicitPath: storePath)
            )

            // The index mode must announce itself.
            #expect(index.notes.contains { $0.contains("--index-store active") })

            // Syntax mode conflates the two `shared()` methods and flags
            // NEITHER (the call keeps both alive).
            #expect(sharedMethodFindings(syntax).isEmpty)

            // Index mode resolves the call to Alpha.shared alone, so Beta.shared
            // is provably dead: exactly one extra unused-function finding.
            let indexShared = sharedMethodFindings(index)
            #expect(indexShared.count == 1)
            #expect(indexShared.first?.rule == .unusedFunction)

            // The finding SETS differ, and differ in the index's favor.
            #expect(index.findings.count == syntax.findings.count + 1)

            // Robustness: pointing the (real) fixture index at an UNRELATED
            // file resolves zero declarations, so the analyzer must fall back
            // to syntax and still flag that file's dead code — never silently
            // mask it behind a mismatched store. Reuses the built index.
            let strayDir = FileManager.default.temporaryDirectory
                .appending(path: "dw-idx-stray-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: strayDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: strayDir) }
            let stray = strayDir.appending(path: "Stray.swift")
            try "private func strayDead() {}\npublic func strayLive() { print(1) }\n"
                .write(to: stray, atomically: true, encoding: .utf8)

            let mismatched = await Analyzer().analyze(
                files: [stray.path],
                indexStore: IndexStoreOptions(enabled: true, explicitPath: storePath)
            )
            #expect(mismatched.notes.contains { $0.contains("does not cover") })
            #expect(mismatched.findings.contains { $0.message.contains("strayDead") })
        }
    }

    // MARK: - Fixture: index-specific false positives

    /// A fixture exercising three index-specific mapping gaps in one build:
    /// a computed property calling another from within its own accessor, a
    /// `@Test` function named with backtick-quoted raw identifier syntax, and
    /// a macro-conforming type whose synthesized conformance extension
    /// shares the type's own name and line.
    struct IndexFalsePositiveFixture {
        let root: URL
        let sourceFile: String
        let testFile: String

        static func create() throws -> IndexFalsePositiveFixture {
            let root = FileManager.default.temporaryDirectory
                .appending(path: "dw-idx-fp-\(UUID().uuidString)")
            var completed = false
            defer {
                if !completed { try? FileManager.default.removeItem(at: root) }
            }
            let sources = root.appending(path: "Sources/IndexFPFixture")
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            let tests = root.appending(path: "Tests/IndexFPFixtureTests")
            try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)

            try """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(
                name: "IndexFPFixture",
                platforms: [.macOS(.v14)],
                targets: [
                    .target(name: "IndexFPFixture"),
                    .testTarget(name: "IndexFPFixtureTests", dependencies: ["IndexFPFixture"]),
                ]
            )
            """.write(to: root.appending(path: "Package.swift"), atomically: true, encoding: .utf8)

            // A computed property (`summary`) whose own accessor calls
            // another computed property (`detail`): the index gives each its
            // own accessor symbol, distinct from the property. A macro
            // ("Observable")-conforming class whose synthesized conformance
            // extension shares the class's own name at the class's own line.
            let source = sources.appending(path: "Sample.swift")
            try """
            import Observation

            @Observable
            public final class SampleEngine {
                public func run() -> String { "ran" }
            }

            public struct SampleReport {
                public let engine = SampleEngine()

                public var summary: String { detail }

                private var detail: String { engine.run() }
            }
            """.write(to: source, atomically: true, encoding: .utf8)

            // A Swift Testing raw-identifier (backtick) test name, using a
            // `sut`-shaped property from its own body — the pervasive
            // convention the backtick-stripping fix targets.
            let test = tests.appending(path: "SampleReportTests.swift")
            try """
            import Testing
            @testable import IndexFPFixture

            struct SampleReportTests {
                private let sut = SampleReport()

                @Test
                func `summary reads the private detail`() {
                    #expect(sut.summary == "ran")
                }
            }
            """.write(to: test, atomically: true, encoding: .utf8)

            completed = true
            return IndexFalsePositiveFixture(root: root, sourceFile: source.path, testFile: test.path)
        }

        var sourceFiles: [String] { [sourceFile, testFile] }

        func buildIndex(swiftPath: String) async -> String? {
            do {
                let result = try await ProcessExecutor.run(
                    executable: URL(fileURLWithPath: swiftPath),
                    arguments: ["build", "--build-tests"],
                    currentDirectory: root,
                    timeout: .seconds(300)
                )
                guard result.succeeded else { return nil }
                return IndexStorePathFinder.findIndexStorePath(in: root.path)
            } catch {
                return nil
            }
        }
    }

    @Suite struct IndexFalsePositiveTests {
        @Test(
            "Index mode roots computed-property chains, backtick test names, and macro-conforming types",
            .enabled(
                if: IndexTestToolchain.isAvailable
                    && ProcessInfo.processInfo.environment["CI"] == nil)
        )
        func indexAvoidsMappingFalsePositives() async throws {
            guard let swiftPath = IndexTestToolchain.swiftPath else { return }

            let fixture = try IndexFalsePositiveFixture.create()
            defer { try? FileManager.default.removeItem(at: fixture.root) }

            guard let storePath = await fixture.buildIndex(swiftPath: swiftPath) else {
                print("IndexFalsePositiveTests: swift build did not produce a readable index; skipping")
                return
            }
            let canonicalSource = IndexBasedDependencyGraph.canonicalPath(fixture.sourceFile)
            guard
                let reader = try? IndexStoreReader(indexStorePath: storePath, allowsDirectoryCreation: true),
                !reader.rawOccurrences(inFile: canonicalSource).isEmpty
            else {
                print("IndexFalsePositiveTests: index opened empty (toolchain mismatch); skipping")
                return
            }

            let report = await Analyzer().analyze(
                files: fixture.sourceFiles,
                indexStore: IndexStoreOptions(enabled: true, explicitPath: storePath)
            )
            #expect(report.notes.contains { $0.contains("--index-store active") })

            // A computed property reached only from within another
            // computed property's own accessor is used.
            #expect(!report.findings.contains { $0.message.contains("'detail'") })
            // A backtick-named @Test function roots what it calls, `sut`
            // included.
            #expect(!report.findings.contains { $0.message.contains("'sut'") })
            // The macro-conforming class is not confused with its
            // synthesized conformance extension.
            #expect(!report.findings.contains { $0.message.contains("SampleEngine") })
        }
    }
#endif
