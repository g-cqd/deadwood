import DeadwoodCore
import Testing

/// The benchmark package's only failure mode is dependency drift against the
/// parent — prove the graph is intact with one real analysis round-trip.
@Suite struct BenchmarksSmokeTests {
    @Test func parentProductIsUsable() {
        let report = Analyzer().analyze(
            source: """
                private func neverCalled() {}
                @main struct M { static func main() {} }
                """,
            path: "smoke.swift"
        )
        #expect(report.findings.map(\.rule) == [.unusedFunction])
    }
}
