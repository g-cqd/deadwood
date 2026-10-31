//  Ported from SwiftStaticAnalysis UnusedCodeDetectorTests: the
//  FilterConfiguration/FilterMethod/ShouldExclude/TestSuiteName/
//  BacktickedIdentifier/GlobPatternMatching/IgnoredPatterns suites,
//  consolidated against the trimmed filter surface.

import SymbolFacts
import Testing

@testable import DeadwoodCore

@Suite("Unused Code Filter")
struct UnusedCodeFilterTests {
    private func item(
        name: String,
        kind: DeclarationKind = .function,
        file: String = "/src/App/Feature.swift"
    ) -> UnusedCode {
        UnusedCode(
            declaration: makeDecl(name: name, kind: kind, access: .private, file: file),
            reason: .neverReferenced,
            confidence: .high
        )
    }

    @Test("Underscore is never reported")
    func underscoreExcluded() {
        let filter = UnusedCodeFilter(configuration: UnusedCodeFilterConfiguration())
        #expect(filter.shouldExclude(item(name: "_")))
    }

    @Test("Deinit exclusion honors configuration")
    func deinitExclusion() {
        let strict = UnusedCodeFilter(configuration: UnusedCodeFilterConfiguration())
        let sensible = UnusedCodeFilter(configuration: .sensibleDefaults)

        #expect(!strict.shouldExclude(item(name: "deinit", kind: .deinitializer)))
        #expect(sensible.shouldExclude(item(name: "deinit", kind: .deinitializer)))
    }

    @Test("Import exclusion honors configuration")
    func importExclusion() {
        let excluding = UnusedCodeFilter(
            configuration: UnusedCodeFilterConfiguration(excludeImports: true))
        let keeping = UnusedCodeFilter(configuration: UnusedCodeFilterConfiguration())

        #expect(excluding.shouldExclude(item(name: "Foundation", kind: .import)))
        #expect(!keeping.shouldExclude(item(name: "Foundation", kind: .import)))
    }

    @Test("Backticked enum cases are excluded under sensible defaults")
    func backtickedEnumCases() {
        let filter = UnusedCodeFilter(configuration: .sensibleDefaults)
        #expect(filter.shouldExclude(item(name: "`default`", kind: .enumCase)))
        #expect(!filter.shouldExclude(item(name: "regular", kind: .enumCase)))
    }

    @Test("Backticked identifier detection")
    func backtickedIdentifiers() {
        #expect(isBacktickedIdentifier("`class`"))
        #expect(isBacktickedIdentifier("`default`"))
        #expect(!isBacktickedIdentifier("plain"))
        #expect(!isBacktickedIdentifier("`"))
        #expect(!isBacktickedIdentifier("``"))
        #expect(!isBacktickedIdentifier("`bad`tick`"))
    }

    @Test("Test suite names are recognized")
    func testSuiteNames() {
        #expect(UnusedCodeFilter.isTestSuiteName("ParserTests"))
        #expect(UnusedCodeFilter.isTestSuiteName("IntegrationTest"))
        #expect(!UnusedCodeFilter.isTestSuiteName("Testable"))
        #expect(!UnusedCodeFilter.isTestSuiteName("Parser"))
    }

    @Test("Test suite exclusion honors configuration")
    func testSuiteExclusion() {
        let filter = UnusedCodeFilter(configuration: .sensibleDefaults)
        #expect(filter.shouldExclude(item(name: "LegacyTests", kind: .class)))
        #expect(!filter.shouldExclude(item(name: "Legacy", kind: .class)))
    }

    @Test("Filter drops excluded items and keeps the rest")
    func filterList() {
        let filter = UnusedCodeFilter(configuration: .sensibleDefaults)
        let items = [
            item(name: "genuinelyDead"),
            item(name: "deinit", kind: .deinitializer),
            item(name: "_"),
        ]

        let kept = filter.filter(items)
        #expect(kept.map(\.declaration.name) == ["genuinelyDead"])
    }
}
