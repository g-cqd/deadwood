// swift-format-ignore-file
// swift-testing suites: @Test functions have arbitrary names (no "test"
// prefix) and are invoked by the framework — they and their helpers must
// never be flagged.
import Testing

@Suite struct ParserBehavior {
    @Test func roundTripsEmptyInput() {
        #expect(parseProbe("") == nil)
    }

    @Test("unicode is preserved") func handlesUnicode() {
        #expect(parseProbe("é") != nil)
    }
}

private func parseProbe(_ s: String) -> Int? { s.isEmpty ? nil : s.count }
