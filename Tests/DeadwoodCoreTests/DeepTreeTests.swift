import DeadwoodCore
import Foundation
import Testing

/// A deeply nested file never crashes the run: one nested within reason is analysed on the large stack, one nested past
/// the limit is listed as skipped, and the rest of the corpus is analysed as usual (analyzerkit roadmap 0041).
@Suite struct DeepTreeTests {
    private static func chain(_ links: Int) -> String {
        "func f() {\n  let v = view" + String(repeating: ".m(1)", count: links) + "\n  print(v)\n}\n"
    }

    @Test func `a deep file is analysed or listed as skipped, and the corpus still reports`() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "deadwood-deep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plain = "struct Plain {\n  private func neverCalled() {}\n  func run() {}\n}\n"
        var paths: [String] = []
        for (name, text) in [("Deep", Self.chain(3_000)), ("Deeper", Self.chain(15_000)), ("Plain", plain)] {
            let url = root.appending(path: "\(name).swift")
            try text.write(to: url, atomically: true, encoding: .utf8)
            paths.append(url.path)
        }
        let report = await Analyzer().analyze(files: paths)
        // An unreferenced type is reported whole, members folded in: Plain.swift and Deep.swift were both analysed.
        let messages = report.findings.map(\.message)
        #expect(messages.contains { $0.contains("struct 'Plain'") }, "\(messages)")
        #expect(messages.contains { $0.contains("function 'f()'") }, "\(messages)")
        let degraded = report.degradedFiles.map { ($0.path as NSString).lastPathComponent }
        #expect(degraded == ["Deeper.swift"])
        #expect(report.degradedFiles.first.map { $0.skipped && $0.detail.contains("nested") } == true)
    }

    @Test func `the single-file entry point lists a file nested past the limit instead of walking it`() {
        let report = Analyzer().analyze(source: Self.chain(15_000), path: "Deeper.swift")
        let skipped = report.degradedFiles.map { $0.skipped && $0.detail.contains("nested") }
        #expect(skipped == [true])
    }
}
