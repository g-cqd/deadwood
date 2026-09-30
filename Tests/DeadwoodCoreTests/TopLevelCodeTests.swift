import DeadwoodCore
import Testing

/// Code at file scope (`#Preview`, script statements) names nothing, so the
/// references made from it used to reach nothing.
@Suite struct TopLevelCodeTests {
    @Test func `declarations used only from a #Preview are used`() async throws {
        let report = try await CorpusFixture([
            "SampleView.swift": """
            import SwiftUI

            struct SampleView: View {
                let title: String
                var body: some View { Text(title) }
            }
            """,
            "SampleView+Preview.swift": """
            import SwiftUI

            #if DEBUG
            #Preview {
                SampleView(title: PreviewData.sampleTitle)
            }

            enum PreviewData {
                static var sampleTitle: String { "Sample" }
            }
            #endif
            """,
        ]).analyze()

        #expect(!report.flags("PreviewData"))
        #expect(!report.flags("sampleTitle"))
    }

    @Test func `locals inside a #Preview are not reported as properties`() async throws {
        let report = try await CorpusFixture([
            "SampleRow.swift": """
            import SwiftUI

            struct SampleRow: View {
                let duration: Double
                var body: some View { Text("\\(duration)") }
            }

            #Preview {
                @Previewable var secondsPerHour = 3600.0
                let sessions = [secondsPerHour, secondsPerHour * 2]
                let firstSample = sessions.first ?? 0
                SampleRow(duration: firstSample)
            }
            """
        ]).analyze()

        #expect(!report.flags("secondsPerHour"))
        #expect(!report.flags("sessions"))
        #expect(!report.flags("firstSample"))
    }

    @Test func `a script's top-level statements use its declarations`() async throws {
        let report = try await CorpusFixture([
            "scripts/cleanup.swift": """
            struct StringsFile {
                let path: String
            }

            func loadFiles() -> [StringsFile] { [StringsFile(path: "a")] }

            func unusedHelper() {}

            Task {
                let files = loadFiles()
                let firstFile = files[0]
                print(firstFile.path)
            }
            """
        ]).analyze()

        #expect(!report.flags("StringsFile"))
        #expect(!report.flags("loadFiles"))
        #expect(!report.flags("files"))
        #expect(!report.flags("firstFile"))
        // Rooting top-level code must not root the whole file.
        #expect(report.flags("unusedHelper"))
    }
}
