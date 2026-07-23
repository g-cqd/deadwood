import DeadwoodCore
import Foundation
import Testing

/// The two opt-in rules: silent under defaults, firing when enabled — both
/// directions pinned so a config regression cannot flip either silently.
@Suite struct OptInRuleTests {
    private func report(
        _ source: String, rules: [String: Configuration.RuleSettings] = [:]
    ) async -> AnalysisReport {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "deadwood-optin-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "Opt.swift")
        try? source.write(to: file, atomically: true, encoding: .utf8)
        let analyzer = Analyzer(configuration: Configuration(rules: rules))
        return await analyzer.analyze(files: [file.path])
    }

    @Test func unusedImportSilentByDefault() async {
        let source = """
            import Foundation
            @main struct M { static func main() {} }
            """
        let report = await report(source)
        #expect(!report.findings.contains { $0.rule == .unusedImport })
    }

    @Test func unusedImportFiresWhenEnabled() async {
        let source = """
            import Foundation
            @main struct M { static func main() {} }
            """
        let report = await report(
            source, rules: ["unused-import": .init(enabled: true)])
        #expect(report.findings.contains { $0.rule == .unusedImport })
    }

    @Test func unusedPublicApiSilentByDefault() async {
        let source = """
            public func exportedHelper() {}
            @main struct M { static func main() {} }
            """
        let report = await report(source)
        #expect(report.findings.isEmpty)
    }

    @Test func unusedPublicApiFiresWhenEnabled() async {
        let source = """
            public func exportedHelper() {}
            @main struct M { static func main() {} }
            """
        let report = await report(
            source, rules: ["unused-public-api": .init(enabled: true)])
        #expect(report.findings.contains { $0.rule == .unusedPublicApi })
    }

    @Test func memberwiseLabelOnLowercaseCalleeIsNotAReference() async {
        // Positive control for the memberwise-label fix: a lowercase callee's
        // argument label must NOT keep a same-named private property alive.
        let source = """
            struct Holder {
                private var retries = 3
            }
            func configure(retries: Int) {}
            @main struct M { static func main() { configure(retries: 1); _ = Holder() } }
            """
        let report = await report(source)
        #expect(report.findings.contains { $0.rule == .unusedProperty })
    }

    // MARK: - @_exported imports

    @Test func exportedImportIsNeverFlagged() async {
        let source = """
            @_exported import Foundation
            @main struct M { static func main() {} }
            """
        let report = await report(
            source, rules: ["unused-import": .init(enabled: true)])
        #expect(!report.findings.contains { $0.rule == .unusedImport })
    }

    // MARK: - assign-only-property

    private static let assignOnlySource = """
        struct Tracker {
            private var count = 0
            mutating func bump() { count = 1 }
        }
        @main struct M { static func main() { var t = Tracker(); t.bump() } }
        """

    @Test func assignOnlySilentByDefault() async {
        let report = await report(Self.assignOnlySource)
        #expect(!report.findings.contains { $0.rule == .assignOnlyProperty })
    }

    @Test func assignOnlyFiresWhenEnabled() async {
        let report = await report(
            Self.assignOnlySource, rules: ["assign-only-property": .init(enabled: true)])
        let finding = report.findings.first { $0.rule == .assignOnlyProperty }
        #expect(finding != nil)
        #expect(finding?.line == 2)
        #expect(finding?.message.contains("count") == true)
    }

    @Test func assignOnlyStaysSilentWhenPropertyIsRead() async {
        // `self.count` is a member access — a potential read — so the rule
        // must not fire even though no `.read` context exists.
        let source = """
            struct Tracker {
                private var count = 0
                mutating func bump() { count = 1 }
                func snapshot() -> Int { self.count }
            }
            @main struct M { static func main() { var t = Tracker(); t.bump(); _ = t.snapshot() } }
            """
        let report = await report(
            source, rules: ["assign-only-property": .init(enabled: true)])
        #expect(!report.findings.contains { $0.rule == .assignOnlyProperty })
    }

    // MARK: - dead-store

    private static let deadStoreSource = """
        func compute() -> Int {
            var x = 1
            x = 2
            return x
        }
        @main struct M { static func main() { _ = compute() } }
        """

    @Test func deadStoreSilentByDefault() async {
        let report = await report(Self.deadStoreSource)
        #expect(!report.findings.contains { $0.rule == .deadStore })
    }

    @Test func deadStoreFiresWhenEnabled() async {
        let report = await report(
            Self.deadStoreSource, rules: ["dead-store": .init(enabled: true)])
        let finding = report.findings.first { $0.rule == .deadStore }
        #expect(finding != nil)
        #expect(finding?.line == 2)
        #expect(finding?.message.contains("'x'") == true)
    }

    @Test func lastWriteIsNotADeadStore() async {
        // `total` is written and never read again, but nothing overwrites
        // it — that is assign-only/unused territory, not a dead store.
        let source = """
            func compute() -> Int {
                var total = 1
                total = 2
                return 0
            }
            @main struct M { static func main() { _ = compute() } }
            """
        let report = await report(
            source, rules: ["dead-store": .init(enabled: true)])
        let deadStores = report.findings.filter { $0.rule == .deadStore }
        // Only the overwritten first store is dead; the surviving last
        // write is not reported.
        #expect(deadStores.count == 1)
        #expect(deadStores.first?.line == 2)
    }
}
