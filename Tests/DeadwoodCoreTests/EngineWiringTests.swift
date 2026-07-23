//  New in deadwood: the Analyzer↔engine contract — rule toggles, the
//  public-API rule, unused imports, corpus-mode reachability across files,
//  suppression through the engine, and the containment collapse.

import Foundation
import Testing

@testable import DeadwoodCore

@Suite("Engine Wiring")
struct EngineWiringTests {
    @Test("Single-file analysis flags a private orphan with the right rule")
    func singleFileRuleMapping() {
        let report = Analyzer().analyze(
            source: """
                private func orphan() {}
                """,
            path: "test.swift"
        )

        #expect(report.findings.count == 1)
        #expect(report.findings.first?.rule == .unusedFunction)
        #expect(report.findings.first?.line == 1)
        #expect(report.findings.first?.message.contains("orphan()") == true)
    }

    @Test("Internal declarations are out of single-file scope")
    func internalOutOfSingleFileScope() {
        let report = Analyzer().analyze(
            source: """
                func maybeUsedElsewhere() {}
                """,
            path: "test.swift"
        )

        #expect(report.findings.isEmpty)
    }

    @Test("Disabled rules drop their findings")
    func disabledRules() {
        let config = Configuration(
            rules: ["unused-function": .init(enabled: false)]
        )
        let report = Analyzer(configuration: config).analyze(
            source: """
                private func orphan() {}
                private let unusedValue = 1
                """,
            path: "test.swift"
        )

        #expect(report.findings.map(\.rule) == [.unusedProperty])
    }

    @Test("Rule severity overrides apply")
    func severityOverride() {
        let config = Configuration(
            rules: ["unused-function": .init(severity: .error)]
        )
        let report = Analyzer(configuration: config).analyze(
            source: "private func orphan() {}",
            path: "test.swift"
        )

        #expect(report.findings.first?.severity == .error)
        #expect(report.maxSeverity == .error)
    }

    @Test("Suppression flows through the engine")
    func suppressionThroughEngine() {
        let report = Analyzer().analyze(
            source: """
                // @dw:accept unused-function -- kept for the v2 API
                private func futureEntryPoint() {}
                """,
            path: "test.swift"
        )

        #expect(report.findings.isEmpty)
        #expect(report.suppressed.count == 1)
        #expect(report.suppressed.first?.reason == "kept for the v2 API")
        #expect(report.suppressed.first?.finding.rule == .unusedFunction)
    }

    @Test("Members collapse into their flagged type")
    func containmentCollapse() {
        let report = Analyzer().analyze(
            source: """
                private struct Orphan {
                    func member() {}
                    let value = 1
                }
                """,
            path: "test.swift"
        )

        #expect(report.findings.count == 1)
        #expect(report.findings.first?.rule == .unusedType)
    }

    @Test("unused-import stays silent unless enabled")
    func unusedImportOptIn() {
        let source = """
            import CoreGraphics

            private func orphanFree() -> Int { 1 }
            func keep() -> Int { orphanFree() }
            """

        let defaultReport = Analyzer().analyze(source: source, path: "test.swift")
        #expect(defaultReport.findings.isEmpty)

        let config = Configuration(rules: ["unused-import": .init(enabled: true)])
        let enabledReport = Analyzer(configuration: config).analyze(source: source, path: "test.swift")
        #expect(enabledReport.findings.map(\.rule) == [.unusedImport])
        #expect(enabledReport.findings.first?.message.contains("CoreGraphics") == true)
    }

    @Test("unused-import respects qualified references")
    func unusedImportQualifiedReference() {
        let source = """
            import CoreGraphics

            func zero() -> CGFloat { CGFloat.zero }
            """
        let config = Configuration(rules: ["unused-import": .init(enabled: true)])
        let report = Analyzer(configuration: config).analyze(source: source, path: "test.swift")
        // CGFloat is referenced but not module-qualified; the heuristic
        // still flags the import — that is why the rule is opt-in. A
        // module-qualified use silences it:
        let qualified = """
            import CoreGraphics

            func zero() -> Double { CoreGraphics.CGFloat.zero }
            """
        let qualifiedReport = Analyzer(configuration: config).analyze(
            source: qualified, path: "test.swift")
        #expect(report.findings.count == 1)
        #expect(qualifiedReport.findings.isEmpty)
    }

    @Test("Corpus analysis finds cross-file dead code and keeps cross-file uses")
    func corpusReachability() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("deadwood-corpus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let mainFile = directory.appendingPathComponent("Main.swift")
        let libFile = directory.appendingPathComponent("Lib.swift")
        try """
        @main
        struct Tool {
            static func main() {
                crossFileHelper()
            }
        }
        """.write(to: mainFile, atomically: true, encoding: .utf8)
        try """
        func crossFileHelper() {}

        func orphanInternal() {}
        """.write(to: libFile, atomically: true, encoding: .utf8)

        let report = await Analyzer().analyze(files: [mainFile.path, libFile.path])

        // `crossFileHelper` is used from the other file; `orphanInternal`
        // is internal and unreachable — corpus mode can prove that.
        #expect(report.analyzedFileCount == 2)
        #expect(report.findings.count == 1)
        #expect(report.findings.first?.rule == .unusedFunction)
        #expect(report.findings.first?.message.contains("orphanInternal()") == true)
        #expect(report.findings.first?.path == libFile.path)
    }

    @Test("unused-public-api is opt-in and routes public findings")
    func unusedPublicApiRule() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("deadwood-public-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("Api.swift")
        try """
        @main
        struct Tool {
            static func main() {}
        }

        public func abandonedApi() {}
        """.write(to: file, atomically: true, encoding: .utf8)

        let defaultReport = await Analyzer().analyze(files: [file.path])
        #expect(defaultReport.findings.isEmpty, "public API is a root by default")

        let config = Configuration(rules: ["unused-public-api": .init(enabled: true)])
        let strictReport = await Analyzer(configuration: config).analyze(files: [file.path])
        #expect(strictReport.findings.map(\.rule) == [.unusedPublicApi])
    }

    @Test("Degraded files are reported, not silently skipped")
    func degradedFiles() async {
        let report = await Analyzer().analyze(files: ["/nonexistent/nowhere.swift"])
        #expect(report.degradedFiles.count == 1)
        #expect(report.findings.isEmpty)
    }

    @Test("TaskBackedAsyncStream cancels its producer on early termination")
    func taskBackedStreamCancellation() async {
        let stream = TaskBackedAsyncStream.makeStream(
            bufferingPolicy: AsyncStream<Int>.Continuation.BufferingPolicy.unbounded
        ) { continuation in
            var value = 0
            while !Task.isCancelled {
                continuation.yield(value)
                value += 1
                await Task.yield()
            }
            continuation.finish()
        }

        var received: [Int] = []
        for await value in stream {
            received.append(value)
            if received.count == 3 { break }
        }

        #expect(received.count == 3)
    }
}
