import DeadwoodCore
import Foundation
import Testing

/// Production mode: reachability computed twice — with test roots and
/// without — over the Fixtures/Production pair. Declarations only tests can
/// reach get `referenced-only-by-tests`; genuinely dead declarations keep
/// their normal rules; test code itself is never the subject.
@Suite struct ProductionModeTests {
    private static let productionDir = Bundle.module.resourceURL!
        .appending(path: "Fixtures/Production")

    private func fixturePaths() throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            at: Self.productionDir, includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "swift" }
        .map(\.path)
        .sorted()
    }

    @Test("Default mode: test-reachable declarations stay alive")
    func defaultModeKeepsTestReachableAlive() async throws {
        let report = await Analyzer().analyze(files: try fixturePaths())

        #expect(!report.findings.contains { $0.rule == .referencedOnlyByTests })
        #expect(!report.findings.contains { $0.message.contains("onlyTestedHelper") })
        // The genuinely dead helper is still found normally.
        #expect(
            report.findings.contains {
                $0.rule == .unusedFunction && $0.message.contains("deadHelper")
            })
    }

    @Test("Production mode: only-tested declarations get their own rule")
    func productionModeSplitsOnlyTested() async throws {
        let configuration = Configuration(production: true)
        let report = await Analyzer(configuration: configuration).analyze(files: try fixturePaths())

        let onlyTested = report.findings.filter { $0.rule == .referencedOnlyByTests }
        #expect(onlyTested.count == 1)
        #expect(onlyTested.first?.message.contains("onlyTestedHelper") == true)
        #expect(onlyTested.first?.severity == .warning)
        #expect(onlyTested.first?.note?.contains("reachable with test roots") == true)

        // Production-reachable code is untouched; the genuinely dead helper
        // keeps its normal rule.
        #expect(!report.findings.contains { $0.message.contains("usedHelper") })
        #expect(
            report.findings.contains {
                $0.rule == .unusedFunction && $0.message.contains("deadHelper")
            })
    }

    @Test("Production mode never points into test code")
    func productionModeExcludesTestCode() async throws {
        let configuration = Configuration(production: true)
        let report = await Analyzer(configuration: configuration).analyze(files: try fixturePaths())

        #expect(
            !report.findings.contains {
                $0.rule == .referencedOnlyByTests && $0.path.hasSuffix("Tests.swift")
            })
    }

    @Test("Disabling the rule silences production mode")
    func ruleToggleSilencesProductionMode() async throws {
        let configuration = Configuration(
            rules: ["referenced-only-by-tests": .init(enabled: false)],
            production: true
        )
        let report = await Analyzer(configuration: configuration).analyze(files: try fixturePaths())

        #expect(!report.findings.contains { $0.rule == .referencedOnlyByTests })
    }
}
