import DeadwoodCore
import Testing

/// ArgumentParser calls `validate()` on every command, and a command is a `ParsableArguments` through `ParsableCommand`,
/// so a command's `validate()` is a witness even though the command never names `ParsableArguments`.
@Suite struct ArgumentParserWitnessTests {
    @Test(arguments: ["ParsableCommand", "AsyncParsableCommand"])
    func `validate on a command is called by the framework`(conformance: String) async throws {
        let report = try await CorpusFixture([
            "Main.swift": """
            import ArgumentParser
            @main
            struct Tool: \(conformance) {
                func validate() throws { try check() }
                func run() throws {}
                func check() throws {}
            }
            """
        ]).analyze()
        #expect(report.findings.isEmpty, "\(report.findings.map(\.message))")
    }

    @Test func `validate on a ParsableArguments group is called by the framework`() async throws {
        let report = try await CorpusFixture([
            "Main.swift": """
            import ArgumentParser
            struct Options: ParsableArguments {
                func validate() throws { try check() }
                func check() throws {}
            }
            struct Use: ParsableCommand {
                @OptionGroup var options: Options
                func run() throws { print(options) }
            }
            print(Use.self)
            """
        ]).analyze()
        #expect(report.findings.isEmpty, "\(report.findings.map(\.message))")
    }
}
