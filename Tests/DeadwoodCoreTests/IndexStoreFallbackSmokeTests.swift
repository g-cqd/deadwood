//  Graceful-fallback smoke test for `--index-store`. Runs on every platform
//  (no index required): it proves that requesting index mode WITHOUT an index
//  never hard-fails — it emits a clear note and returns exactly the syntax
//  result. Uses only the public `Analyzer` + `IndexStoreOptions` surface.

import DeadwoodCore
import Foundation
import Testing

@Suite struct IndexStoreFallbackSmokeTests {
    private func fingerprint(_ report: AnalysisReport) -> [String] {
        report.findings
            .map { "\($0.rule.rawValue):\($0.path):\($0.line):\($0.column):\($0.message)" }
            .sorted()
    }

    @Test func missingIndexFallsBackToSyntaxWithNote() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "dw-idx-fallback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appending(path: "Sample.swift")
        try """
        private func unusedHelper() {}
        public func entry() { print("hi") }
        """.write(to: source, atomically: true, encoding: .utf8)
        let files = [source.path]

        let syntax = await Analyzer().analyze(files: files)
        let fallback = await Analyzer().analyze(
            files: files,
            indexStore: IndexStoreOptions(
                enabled: true,
                explicitPath: "/deadwood-nonexistent-\(UUID().uuidString)/index/store"
            )
        )

        // The syntax run leaves the note channel empty.
        #expect(syntax.notes.isEmpty)
        // A missing index yields a clear fallback note, never a hard failure.
        #expect(fallback.notes.contains { $0.contains("falling back to syntax") })
        // The fallback still produced findings (analysis actually ran).
        #expect(!fallback.findings.isEmpty)
        // And they are exactly the syntax findings — byte-for-byte fallback.
        #expect(fingerprint(fallback) == fingerprint(syntax))
    }

    @Test func defaultRunIsUnchangedByTheIndexPlumbing() async throws {
        // Regression pin: with index mode OFF (the default), the report carries
        // no notes and the findings are the plain syntax result.
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "dw-idx-default-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appending(path: "Sample.swift")
        try "private struct Unused {}\n".write(to: source, atomically: true, encoding: .utf8)

        let explicitDefault = await Analyzer().analyze(
            files: [source.path], indexStore: .disabled)
        let implicitDefault = await Analyzer().analyze(files: [source.path])

        #expect(explicitDefault.notes.isEmpty)
        #expect(fingerprint(explicitDefault) == fingerprint(implicitDefault))
        #expect(explicitDefault.findings.contains { $0.rule == .unusedType })
    }
}
