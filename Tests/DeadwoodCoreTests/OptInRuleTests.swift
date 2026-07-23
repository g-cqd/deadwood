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
}
