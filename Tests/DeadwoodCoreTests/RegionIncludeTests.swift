import DeadwoodCore
import Testing

/// `--include`/`--exclude`: dead code inside a region is reported like any
/// other once the region is included, and a root — a preview, a test, a
/// script's top level — is never reported, included or not.
@Suite struct RegionIncludeTests {
    private func find(_ name: String, in report: AnalysisReport) -> Finding? {
        report.findings.first { $0.message.contains("'\(name)") }
    }

    // MARK: - Generated

    private static let generatedFile = """
        // Generated using a template — DO NOT EDIT
        enum SampleAsset {
            static let used = "used"
            static let unused = "unused"
        }
        """
    private static let generatedFiles: [String: String] = [
        "Sources/Generated/Assets.swift": generatedFile,
        "Sources/App.swift": """
        @main
        struct SampleApp {
            static func main() { print(SampleAsset.used) }
        }
        """,
    ]

    @Test func `a generated declaration is withheld by default`() async throws {
        let report = try await CorpusFixture(Self.generatedFiles).analyze()

        #expect(find("unused", in: report) == nil)
        #expect(report.notes.contains { $0.contains("nothing outside it names") })
    }

    @Test func `including generated reports a genuinely unused generated declaration`() async throws {
        let configuration = Configuration(includeRegions: "generated")
        let report = try await CorpusFixture(Self.generatedFiles).analyze(configuration: configuration)

        let finding = try #require(find("unused", in: report))
        #expect(finding.note?.contains("region: generated") == true)
        // The used member, and the type itself, stay unreported.
        #expect(find("SampleAsset", in: report) == nil)
    }

    @Test func `excluding generated wins over including everything`() async throws {
        let configuration = Configuration(includeRegions: "all", excludeRegions: "generated")
        let report = try await CorpusFixture(Self.generatedFiles).analyze(configuration: configuration)

        #expect(find("unused", in: report) == nil)
    }

    // MARK: - Preview

    private static let previewFile = """
        import SwiftUI

        struct SampleView: View {
            var body: some View { Text("sample") }
        }

        func previewOnlyHelper() -> String { "sample" }

        #Preview {
            SampleView().padding(previewOnlyHelper().count == 0 ? 0 : 8)
        }
        """

    @Test func `production code reachable only from a preview is a note by default`() async throws {
        let report = try await CorpusFixture(["Sources/SampleView.swift": Self.previewFile]).analyze()

        let finding = try #require(find("previewOnlyHelper", in: report))
        #expect(finding.severity == .note)
        #expect(finding.rule == .previewOnly)
    }

    @Test func `including preview promotes it to a normal finding, tagged`() async throws {
        let configuration = Configuration(includeRegions: "preview")
        let report = try await CorpusFixture(["Sources/SampleView.swift": Self.previewFile])
            .analyze(configuration: configuration)

        let finding = try #require(find("previewOnlyHelper", in: report))
        #expect(finding.severity == .warning)
        #expect(finding.rule == .unusedFunction)
        #expect(finding.note?.contains("region: preview") == true)
    }

    @Test func `the preview itself is never reported, included or not`() async throws {
        let configuration = Configuration(includeRegions: "all")
        let report = try await CorpusFixture(["Sources/SampleView.swift": Self.previewFile])
            .analyze(configuration: configuration)

        #expect(!report.findings.contains { $0.path.hasSuffix("SampleView.swift") && $0.line >= 9 })
    }

    // MARK: - Debug

    private static let debugFile = """
        @main
        struct SampleApp {
            static func main() {
                #if DEBUG
                debugOnlyHelper()
                #endif
                print("started")
            }
        }

        func debugOnlyHelper() {}
        """

    @Test func `production code reachable only from #if DEBUG is a note by default`() async throws {
        let report = try await CorpusFixture(["Sources/SampleApp.swift": Self.debugFile]).analyze()

        let finding = try #require(find("debugOnlyHelper", in: report))
        #expect(finding.severity == .note)
        #expect(finding.rule == .debugOnly)
    }

    @Test func `including debug promotes it to a normal finding, tagged`() async throws {
        let configuration = Configuration(includeRegions: "debug")
        let report = try await CorpusFixture(["Sources/SampleApp.swift": Self.debugFile])
            .analyze(configuration: configuration)

        let finding = try #require(find("debugOnlyHelper", in: report))
        #expect(finding.severity == .warning)
        #expect(finding.note?.contains("region: debug") == true)
    }

    // MARK: - A used declaration is never reported, in any region

    @Test func `a helper a live path also uses stays unreported when its region is included`() async throws {
        let configuration = Configuration(includeRegions: "all")
        let source = """
            import SwiftUI

            struct SampleView: View {
                var body: some View { Text(sharedHelper()) }
            }

            func sharedHelper() -> String { "sample" }

            @main
            struct SampleApp {
                static func main() { print(sharedHelper()) }
            }

            #Preview {
                SampleView()
            }
            """
        let report = try await CorpusFixture(["Sources/Sample.swift": source]).analyze(configuration: configuration)

        #expect(find("sharedHelper", in: report) == nil)
    }

    // MARK: - Unknown region name

    @Test func `an unknown region name fails the config, not silently`() {
        #expect(throws: (any Error).self) {
            try Configuration(includeRegions: "bogus").regionSelection()
        }
    }
}
