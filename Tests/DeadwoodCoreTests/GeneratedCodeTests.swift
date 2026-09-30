import DeadwoodCore
import Testing

/// Generated files are never the subject of a finding, but what they use
/// stays used.
@Suite struct GeneratedCodeTests {
    @Test func `generated declarations are not reported, and a note counts the ones nothing names`() async throws {
        let report = try await CorpusFixture([
            "Sources/Sample/Assets.swift": """
            // swiftlint:disable all
            // Generated using SwiftGen — https://github.com/SwiftGen/SwiftGen

            enum Asset {
                static let brandColor = SampleColor(name: "brandColor")
                static let unusedColor = SampleColor(name: "unusedColor")
                static let unusedImage = SampleColor(name: "unusedImage")
            }
            """,
            "Sources/Sample/SampleColor.swift": """
            struct SampleColor {
                let name: String
            }
            """,
            "Sources/Sample/Screen.swift": """
            @main
            struct Screen {
                static func main() {
                    print(Asset.brandColor.name)
                }
            }
            """,
        ]).analyze()

        #expect(!report.flags("unusedColor"))
        #expect(!report.flags("unusedImage"))
        #expect(report.findings.allSatisfy { !$0.path.hasSuffix("Assets.swift") })
        #expect(report.notes.contains { $0.contains("Assets.swift has 2 declaration(s) nothing outside it names") })
    }

    @Test func `hand-written code used only by generated code stays used`() async throws {
        let report = try await CorpusFixture([
            "Sources/Sample/Generated/Strings.swift": """
            enum Strings {
                static let title = SampleLocalizer.text("title")
            }
            """,
            "Sources/Sample/SampleLocalizer.swift": """
            enum SampleLocalizer {
                static func text(_ key: String) -> String { key }
                static func unusedHelper() {}
            }
            """,
        ]).analyze()

        #expect(!report.flags("text"))
        #expect(report.flags("unusedHelper"))
    }
}
