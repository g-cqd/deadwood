import DeadwoodCore
import Testing

@Suite struct SubscriptReachabilityTests {
    private func messages(_ report: AnalysisReport) -> [String] { report.findings.map(\.message) }

    @Test func `references inside an internal static subscript are followed from the enclosing type`() async throws {
        let report = try await CorpusFixture([
            "Recorded.swift": """
            enum Recorded {
                static let descriptions: [String: Int] = ["a": 1]
                static let unusedTable: [String: Int] = ["b": 2]

                static subscript(_ key: String) -> Int { descriptions[key] ?? 0 }
            }

            public func entry() -> Int { Recorded["a"] }
            """
        ]).analyze()
        let msgs = messages(report)
        #expect(!msgs.contains { $0.contains("'descriptions'") }, "\(msgs)")
        #expect(msgs.contains { $0.contains("'unusedTable'") }, "\(msgs)")
    }

    @Test func `references inside an internal instance subscript are followed from the enclosing type`() async throws {
        let report = try await CorpusFixture([
            "Store.swift": """
            struct Store {
                private let backing: [String: Int] = ["k": 7]

                subscript(_ key: String) -> Int { backing[key] ?? 0 }
            }

            public func read(_ store: Store) -> Int { store["k"] }
            """
        ]).analyze()
        #expect(messages(report).isEmpty, "\(messages(report))")
    }

    @Test func `subscript on an unreferenced type does not keep its referenced helpers alive`() async throws {
        let report = try await CorpusFixture([
            "Dead.swift": """
            enum DeadType {
                static let onlyInDeadSubscript: [String: Int] = ["a": 1]
                static subscript(_ key: String) -> Int { onlyInDeadSubscript[key] ?? 0 }
            }
            """
        ]).analyze()
        let msgs = messages(report)
        #expect(msgs.contains { $0.contains("'DeadType'") }, "\(msgs)")
    }
}
