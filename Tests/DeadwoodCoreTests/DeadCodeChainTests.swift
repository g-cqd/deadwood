import DeadwoodCore
import Testing

/// Dead code comes in chains: what only dead code uses is dead too, and is
/// reported in the same run, grouped under the head of its chain.
@Suite struct DeadCodeChainTests {
    private func finding(_ name: String, in report: AnalysisReport) -> Finding? {
        report.findings.first { $0.message.contains("'\(name)") }
    }

    @Test func `a chain of three is one group headed by the declaration nothing names`() async throws {
        let report = try await CorpusFixture([
            "Chain.swift": """
            func startExport() {
                prepareExport()
            }

            func prepareExport() {
                writeExport()
            }

            func writeExport() {}
            """
        ]).analyze()

        let head = try #require(finding("startExport", in: report))
        #expect(head.rule == .unusedFunction)
        #expect(head.note?.contains("2 declaration(s) only it uses are dead with it") == true)
        #expect(finding("prepareExport", in: report)?.rule == .unusedTransitively)
        let middle = finding("prepareExport", in: report)?.message
        let leaf = finding("writeExport", in: report)?.message
        #expect(middle?.hasSuffix("only used by dead code: startExport()") == true)
        #expect(leaf?.hasSuffix("only used by dead code: prepareExport()") == true)
    }

    @Test func `a dead cycle is one group`() async throws {
        let report = try await CorpusFixture([
            "Cycle.swift": """
            func ping(_ count: Int) {
                if count > 0 { pong(count - 1) }
            }

            func pong(_ count: Int) {
                if count > 0 { ping(count - 1) }
            }
            """
        ]).analyze()

        #expect(finding("ping", in: report)?.rule == .unusedFunction)
        #expect(finding("ping", in: report)?.message.contains("a cycle nothing live reaches: pong(_:)") == true)
        #expect(finding("pong", in: report)?.rule == .unusedTransitively)
        #expect(report.findings.count == 2)
    }

    @Test func `a helper that live code also uses stays live`() async throws {
        let report = try await CorpusFixture([
            "App.swift": """
            @main
            enum SampleApp {
                static func main() {
                    sharedHelper()
                }
            }

            func deadCaller() {
                sharedHelper()
            }

            func sharedHelper() {}
            """
        ]).analyze()

        #expect(report.findings.map(\.rule) == [.unusedFunction])
        #expect(finding("deadCaller", in: report) != nil)
    }

    @Test func `a live container does not keep alive what its dead members use`() async throws {
        let report = try await CorpusFixture([
            "Metrics.swift": """
            @main
            enum SampleApp {
                static func main() {
                    SampleMetrics.record()
                }
            }

            enum SampleMetrics {
                static func record() {}
            }

            extension SampleMetrics {
                static func renderedSummary() -> String {
                    let summaryValue = computeSummary()
                    return "\\(summaryValue)"
                }

                private static func computeSummary() -> Int { 1 }
            }
            """
        ]).analyze()

        #expect(finding("renderedSummary", in: report)?.rule == .unusedFunction)
        let helper = try #require(finding("computeSummary", in: report))
        #expect(helper.rule == .unusedTransitively)
        // Private alone would be high; the chain is as sure as its head.
        #expect(helper.note?.hasPrefix("confidence medium") == true)
        // A local dies with its function and is not reported apart.
        #expect(finding("summaryValue", in: report) == nil)
    }
}
