import DeadwoodCore
import Testing

/// A reference to a type reaches an extension of it however the extension spells the type: `extension Outer.Inner`,
/// `extension Box<Int>` and `extension Module.Outer.Inner` all extend what `Inner` and `Box` name.
@Suite struct QualifiedExtensionTests {
    private func names(_ report: AnalysisReport) -> [String] { report.findings.map(\.message) }

    @Test func `an extension of a nested type keeps what its initializer reads`() async throws {
        let report = try await CorpusFixture([
            "A.swift": """
            enum Workspace {
                struct Options { var exclude: [String] }
                static func open(_ options: Options) -> Int { options.exclude.count }
            }
            struct Input { var excludePaths: [String] = [] }
            extension Workspace.Options {
                init(input: Input) { self.init(exclude: input.excludePaths) }
            }
            print(Workspace.open(.init(input: Input())))
            """
        ]).analyze()
        #expect(names(report).isEmpty, "\(names(report))")
    }

    @Test func `an extension of a generic specialization keeps what its method reads`() async throws {
        let report = try await CorpusFixture([
            "A.swift": """
            struct Box<Value> { var value: Value }
            struct Limits { var maximum = 3 }
            extension Box<Int> {
                func clamped(_ limits: Limits) -> Int { min(value, limits.maximum) }
            }
            print(Box(value: 4).clamped(Limits()))
            """
        ]).analyze()
        #expect(names(report).isEmpty, "\(names(report))")
    }

    @Test func `an extension of a nested type nothing uses stays dead`() async throws {
        let report = try await CorpusFixture([
            "A.swift": """
            enum Workspace {
                struct Options { var exclude: [String] = [] }
            }
            struct Input { var excludePaths: [String] = [] }
            extension Workspace.Options {
                func unused(_ input: Input) -> Int { input.excludePaths.count }
            }
            print(Workspace.self)
            """
        ]).analyze()
        #expect(names(report).contains { $0.contains("'unused(") })
    }
}
