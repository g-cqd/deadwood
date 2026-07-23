//  Ported from SwiftStaticAnalysis UnusedCodeDetectorTests: the
//  FilterConfiguration/FilterMethod/ShouldExclude/TestSuiteName/
//  BacktickedIdentifier/GlobPatternMatching/IgnoredPatterns suites,
//  consolidated against the trimmed filter surface.

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

    @Test("Common path globs use fast paths")
    func commonPathGlobs() {
        let filter = UnusedCodeFilter(
            configuration: UnusedCodeFilterConfiguration(
                excludePathPatterns: ["**/Tests/**", "**/*Tests.swift", "**/Fixtures/**"]
            ))

        #expect(filter.shouldExclude(item(name: "x", file: "/pkg/Tests/Feature/Case.swift")))
        #expect(filter.shouldExclude(item(name: "x", file: "/pkg/Sources/FeatureTests.swift")))
        #expect(filter.shouldExclude(item(name: "x", file: "/pkg/Fixtures/Sample.swift")))
        #expect(!filter.shouldExclude(item(name: "x", file: "/pkg/Sources/Feature.swift")))
    }

    @Test("Custom path globs are anchored whole matches")
    func customPathGlobs() {
        let filter = UnusedCodeFilter(
            configuration: UnusedCodeFilterConfiguration(
                excludePathPatterns: ["**/Generated/*.swift"]
            ))

        #expect(filter.shouldExclude(item(name: "x", file: "/pkg/Generated/Models.swift")))
        #expect(!filter.shouldExclude(item(name: "x", file: "/pkg/Handwritten/Models.swift")))
    }

    @Test("Name patterns are regular expressions")
    func namePatterns() {
        let filter = UnusedCodeFilter(
            configuration: UnusedCodeFilterConfiguration(
                excludeNamePatterns: ["^mock", "Stub$"]
            ))

        #expect(filter.shouldExclude(item(name: "mockService")))
        #expect(filter.shouldExclude(item(name: "networkStub")))
        #expect(!filter.shouldExclude(item(name: "realService")))
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

    // MARK: - Glob matcher (canonical translation)

    @Test("Glob translation handles the documented tokens")
    func globTranslation() {
        #expect(GlobMatcher.matches(path: "a/b/c.swift", pattern: "**/*.swift"))
        #expect(GlobMatcher.matches(path: "c.swift", pattern: "**/*.swift"))
        #expect(GlobMatcher.matches(path: "a/Tests/x", pattern: "**/Tests/**"))
        #expect(GlobMatcher.matches(path: "Tests/x", pattern: "**/Tests/**"))
        #expect(!GlobMatcher.matches(path: "a/b/c.swift", pattern: "*.swift"))
        #expect(GlobMatcher.matches(path: "file1.swift", pattern: "file?.swift"))
        #expect(!GlobMatcher.matches(path: "file12.swift", pattern: "file?.swift"))
    }

    @Test("Glob metacharacters are treated literally")
    func globMetacharacters() {
        #expect(GlobMatcher.matches(path: "a+b.swift", pattern: "a+b.swift"))
        #expect(!GlobMatcher.matches(path: "aab.swift", pattern: "a+b.swift"))
        #expect(GlobMatcher.matches(path: "x(1).swift", pattern: "x(1).swift"))
    }

    @Test("Pathological glob patterns fail closed")
    func pathologicalGlobs() {
        // SafeRegex's prefilter rejects nested quantifiers; the defensive
        // default is "no match".
        #expect(!GlobMatcher.matches(path: "anything", pattern: "(a+)+"))
    }

    @Test("Ignored name patterns suppress simple-mode candidates")
    func ignoredPatterns() {
        let source = """
            private func mockHelper() {}
            private func realOrphan() {}
            """
        let result = makeFacts(source)
        let context = CorpusContext(result: result)
        let detector = UnusedCodeDetector(
            configuration: UnusedCodeConfiguration(
                mode: .simple,
                ignoredPatterns: ["^mock"]
            ))

        let names = detector.detectFromResult(result, context: context).map(\.declaration.name)
        #expect(names == ["realOrphan"])
    }
}
