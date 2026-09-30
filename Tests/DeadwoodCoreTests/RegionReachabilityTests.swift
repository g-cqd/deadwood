import DeadwoodCore
import Testing

/// Code only previews or `#if DEBUG` code use is used, but production code
/// in that situation ships in release builds for nothing: a note says so.
@Suite struct RegionReachabilityTests {
    private static let sampleView = """
        import SwiftUI

        struct SampleView: View {
            var body: some View { Text("Sample") }
        }
        """

    @Test func `production code only a preview uses gets a preview-only note`() async throws {
        let report = try await CorpusFixture([
            "SampleView.swift": Self.sampleView,
            "SampleModifiers.swift": """
            import SwiftUI

            extension View {
                func sampleModifier() -> some View { self }
            }

            #Preview {
                SampleView().sampleModifier()
            }
            """,
        ]).analyze()

        let notes = report.findings.filter { $0.rule == .previewOnly }
        #expect(notes.count == 1)
        #expect(notes.first?.message.contains("'sampleModifier()'") == true)
        #expect(notes.first?.severity == .note)
        #expect(!report.findings.contains { $0.rule == .unusedFunction })
    }

    @Test func `code already in #if DEBUG is never reported`() async throws {
        let report = try await CorpusFixture([
            "SampleView.swift": Self.sampleView,
            "SampleView+Preview.swift": """
            import SwiftUI

            #if DEBUG
            #Preview {
                SampleView().padding(PreviewData.spacing)
            }

            enum PreviewData {
                static var spacing: Double { 8 }
            }
            #endif
            """,
        ]).analyze()

        #expect(report.findings.isEmpty)
    }

    @Test func `production code only #if DEBUG code uses gets a debug-only note`() async throws {
        let report = try await CorpusFixture([
            "DebugPanel.swift": """
            @main
            struct SampleApp {
                static func main() {
                    #if DEBUG
                    DebugPanel.dumpState()
                    #endif
                    print("started")
                }
            }

            enum DebugPanel {
                static func dumpState() {}
            }
            """
        ]).analyze()

        let notes = report.findings.filter { $0.rule == .debugOnly }
        #expect(
            notes.map(\.message) == ["enum 'DebugPanel' is used only by #if DEBUG code but ships in release builds"])
        #expect(notes.first?.severity == .note)
    }

    @Test func `the note rules can be turned off`() async throws {
        let configuration = Configuration(rules: [
            "preview-only": .init(enabled: false), "debug-only": .init(enabled: false),
        ])
        let report = try await CorpusFixture([
            "SampleView.swift": Self.sampleView,
            "SampleModifiers.swift": """
            import SwiftUI

            extension View {
                func sampleModifier() -> some View { self }
            }

            #Preview {
                SampleView().sampleModifier()
            }
            """,
        ]).analyze(configuration: configuration)

        #expect(report.findings.isEmpty)
    }
}
