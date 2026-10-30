import DeadwoodCore
import Testing

/// By name, a call with argument labels names the function those labels fit, not a property of the same base name
/// (analyzerkit roadmap 0058; swift-search found the shape in its own lineage). Without an index store,
/// `Converter().location(for:)` counted as a use of an unread `Position.location`, which was never reported.
@Suite struct LabelledCallTests {
    private func finding(_ name: String, in report: AnalysisReport) -> Finding? {
        report.findings.first { $0.message.contains("'\(name)'") }
    }

    private static func program(
        _ use: String, property: String = "var location: String { \"L\\(line)\" }",
        function: String = "func location(for offset: Int) -> Int { offset }"
    ) -> String {
        """
        struct Position {
            let line: Int
            \(property)
        }

        struct Converter {
            \(function)
        }

        @main
        struct Main {
            static func main() {
                let p = Position(line: 1)
                \(use)
            }
        }
        """
    }

    @Test func `a labelled call of a function is not a use of a property named like it`() async throws {
        let report = try await CorpusFixture([
            "Main.swift": Self.program("print(Converter().location(for: p.line))")
        ]).analyze()
        #expect(finding("location", in: report)?.rule == .unusedProperty)
    }

    @Test func `reading the property is still a use`() async throws {
        let report = try await CorpusFixture([
            "Main.swift": Self.program("print(p.location, Converter().location(for: p.line))")
        ]).analyze()
        #expect(finding("location", in: report) == nil)
    }

    /// No function `location(input:)` exists, so the call may be `callAsFunction` on the property's type.
    @Test func `a labelled call no function fits stays a use of the property`() async throws {
        let report = try await CorpusFixture([
            "Main.swift": Self.program(
                "print(p.location(input: 1), Converter().location(for: p.line))",
                property: "var location: Caller { Caller() }")
                + "\nstruct Caller { func callAsFunction(input: Int) -> Int { input } }\n"
        ]).analyze()
        #expect(finding("location", in: report) == nil)
    }

    @Test func `a property of function type called with the labels' arity stays used`() async throws {
        let report = try await CorpusFixture([
            "Main.swift": Self.program(
                "print(p.location(1))", property: "var location: (Int) -> Int = { $0 }")
        ]).analyze()
        #expect(finding("location", in: report) == nil)
    }

    @Test func `a defaulted parameter may be left out of the call`() async throws {
        let report = try await CorpusFixture([
            "Main.swift": Self.program(
                "print(Converter().location(for: p.line))",
                function: "func location(for offset: Int, scale: Int = 1) -> Int { offset * scale }")
        ]).analyze()
        #expect(finding("location", in: report)?.rule == .unusedProperty)
    }
}
