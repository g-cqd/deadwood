import DeadwoodCore
import Testing

/// A name in a string literal is a possible dynamic reference only when the
/// literal is somewhere else than the declaration itself; a name in a
/// comment is a hint, never a demotion.
@Suite struct ConfidenceRefinementTests {
    private func note(for name: String, in report: AnalysisReport) -> String? {
        report.findings.first { $0.message.contains("'\(name)") }?.note
    }

    @Test func `a name only in its own string literal is not demoted`() async throws {
        let report = try await CorpusFixture([
            "SampleMock.swift": """
            final class SampleMock {
                func record() {
                    print("SampleMock.record called")
                }
            }
            """
        ]).analyze()

        #expect(note(for: "SampleMock", in: report) == "confidence medium — no reference found")
    }

    @Test func `a name in another file's string literal is demoted`() async throws {
        let report = try await CorpusFixture([
            "SampleMigrator.swift": """
            final class SampleMigrator {}
            """,
            "Loader.swift": """
            @main
            enum Loader {
                static func main() {
                    print("SampleMigrator")
                }
            }
            """,
        ]).analyze()

        #expect(note(for: "SampleMigrator", in: report)?.hasPrefix("confidence low") == true)
    }

    @Test func `a name in a generated file's string literal is not demoted`() async throws {
        let report = try await CorpusFixture([
            "SampleHelper.swift": """
            enum SampleHelper {}
            """,
            "Generated/Strings.swift": """
            // Generated using SwiftGen
            enum Strings {
                static let key = "SampleHelper"
            }
            """,
        ]).analyze()

        #expect(note(for: "SampleHelper", in: report) == "confidence medium — no reference found")
    }

    @Test func `a name in commented-out code adds a hint, not a demotion`() async throws {
        let report = try await CorpusFixture([
            "SampleTests.swift": """
            import XCTest

            final class SampleTests: XCTestCase {
                private let sampleParticipant = 1

                // func testParticipant() {
                //     XCTAssertEqual(sampleParticipant, 1)
                // }
            }
            """
        ]).analyze()

        let note = note(for: "sampleParticipant", in: report)
        #expect(note?.hasPrefix("confidence high") == true)
        #expect(note?.contains("also named in a comment") == true)
    }
}
