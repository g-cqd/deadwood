import DeadwoodCore
import Foundation
import Testing

/// The composite confidence model: dead branches are certain, the base
/// follows effective access, and dynamic-reference risk demotes — a name
/// appearing in a string literal, or membership in an NSObject subclass
/// without @objc. Confidence and demotions surface in the finding note.
@Suite struct ConfidenceTests {
    @Test("Dead branches are certain")
    func deadBranchIsCertain() {
        let report = Analyzer().analyze(
            source: """
                func gated() -> Int {
                    if false { return 1 }
                    return 0
                }
                """,
            path: "test.swift"
        )

        #expect(report.findings.first?.rule == .deadBranch)
        #expect(report.findings.first?.note?.hasPrefix("confidence certain") == true)
    }

    @Test("Private orphans are high confidence")
    func privateOrphanIsHigh() {
        let report = Analyzer().analyze(
            source: "private func orphan() {}",
            path: "test.swift"
        )

        #expect(report.findings.first?.note?.hasPrefix("confidence high") == true)
    }

    @Test("A name inside a string literal demotes to low with a note")
    func stringLiteralNameDemotes() {
        let report = Analyzer().analyze(
            source: """
                import Foundation

                private final class LegacyMigrator {
                    func migrate() {}
                }

                func loadMigratorClass() -> AnyClass? {
                    NSClassFromString("LegacyMigrator")
                }

                @main
                struct M {
                    static func main() { _ = loadMigratorClass() }
                }
                """,
            path: "test.swift"
        )

        let finding = report.findings.first { $0.rule == .unusedType }
        #expect(finding != nil)
        #expect(finding?.note?.hasPrefix("confidence low") == true)
        #expect(
            finding?.note?.contains(
                "name appears in a string literal — possible dynamic reference") == true)
    }

    @Test("Members of NSObject subclasses without @objc demote one step")
    func objcAdjacentDemotes() {
        let report = Analyzer().analyze(
            source: """
                import Foundation

                private final class Handler: NSObject {
                    private func onTap() {}
                }

                func makeHandler() -> Handler { Handler() }

                @main
                struct M {
                    static func main() { _ = makeHandler() }
                }
                """,
            path: "test.swift"
        )

        let finding = report.findings.first { $0.message.contains("onTap") }
        #expect(finding != nil)
        // Effectively private would be high; NSObject adjacency demotes to
        // medium and says why.
        #expect(finding?.note?.hasPrefix("confidence medium") == true)
        #expect(finding?.note?.contains("NSObject subclass without @objc") == true)
    }

    @Test("@objc members are roots, not demoted findings")
    func objcMembersStayRooted() {
        let report = Analyzer().analyze(
            source: """
                import Foundation

                private final class Handler: NSObject {
                    @objc private func onTap() {}
                }

                func makeHandler() -> Handler { Handler() }

                @main
                struct M {
                    static func main() { _ = makeHandler() }
                }
                """,
            path: "test.swift"
        )

        #expect(!report.findings.contains { $0.message.contains("onTap") })
    }
}
