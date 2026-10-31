import SymbolFacts
import Testing

@testable import DeadwoodCore

/// deadwood's per-file facts are analyzerkit's `SymbolFacts` (roadmap 0055), with what deadwood never read left out:
/// macro declarations, which it does not report.
@Suite struct SymbolFactsAdoptionTests {
    @Test func `the facts are SymbolFacts' declarations, macro declarations left out`() throws {
        let facts = StaticAnalyzer().collectFacts(
            source: "@freestanding(expression)\nmacro m(_ v: Int) -> Int = #externalMacro(module: \"M\", type: \"T\")\n"
                + "@MainActor struct S {}\n",
            file: "F.swift")
        let declarations: [SymbolFacts.Declaration] = facts.declarations
        #expect(declarations.map(\.name) == ["v", "S"])
        let s = try #require(declarations.last)
        #expect((s.location.column, s.nameLocation.column) == (1, 19))
    }
}
