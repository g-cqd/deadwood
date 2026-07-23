//  Ported from SwiftStaticAnalysis UnusedCodeDetectorTests/SwiftSyntaxModeTests
//  (adapted: the detector consumes collected facts; the false-positive
//  prevention scenarios run through the same simple mode the single-file
//  Analyzer path uses).

import Testing

@testable import DeadwoodCore

@Suite("Simple Mode Detection")
struct SimpleModeTests {
    /// Single-file semantics, as the Analyzer wires them: internal-or-wider
    /// declarations are roots (another file could use them).
    static var singleFileConfig: UnusedCodeConfiguration {
        UnusedCodeConfiguration(mode: .simple, treatVisibleOutsideFileAsRoot: true)
    }

    private func detect(
        _ source: String,
        configuration: UnusedCodeConfiguration = Self.singleFileConfig
    ) -> [UnusedCode] {
        let result = makeFacts(source)
        let context = CorpusContext(result: result)
        return UnusedCodeDetector(configuration: configuration)
            .detectFromResult(result, context: context)
    }

    @Test("Detect unused private functions")
    func unusedPrivateFunctions() {
        let findings = detect(
            """
            struct Service {
                func used() -> Int { helper() }
                private func helper() -> Int { 1 }
                private func orphan() -> Int { 2 }
            }
            """)

        #expect(findings.map(\.declaration.name) == ["orphan"])
        #expect(findings.first?.reason == .neverReferenced)
    }

    @Test("Detect unused variables")
    func unusedVariables() {
        let findings = detect(
            """
            private let unusedConstant = 1
            private var unusedVariable = 2
            private let usedConstant = 3
            func use() -> Int { usedConstant }
            """)

        #expect(Set(findings.map(\.declaration.name)) == ["unusedConstant", "unusedVariable"])
    }

    @Test("Detect unused types")
    func unusedTypes() {
        let findings = detect(
            """
            private struct Orphan {}
            private struct Used {}
            func make() -> Used { Used() }
            """)

        #expect(findings.map(\.declaration.name) == ["Orphan"])
        #expect(findings.first?.declaration.kind == .struct)
    }

    @Test("Confidence reflects effective access")
    func confidenceLevels() {
        let findings = detect(
            """
            private func orphan() {}
            """)

        #expect(findings.first?.confidence == .high)
    }

    @Test("Members of private types are effectively private")
    func effectiveAccessThroughContainment() {
        let findings = detect(
            """
            private struct Used {
                func neverCalled() {}
            }
            func make() -> Used { Used() }
            """)

        // `neverCalled` is declared internal but sits inside a private
        // struct — effectively private, hence high confidence.
        #expect(findings.map(\.declaration.name) == ["neverCalled"])
        #expect(findings.first?.confidence == .high)
    }

    @Test("Minimum confidence filters findings")
    func minimumConfidence() {
        let source = """
            private func orphan() {}
            """
        var config = UnusedCodeConfiguration(mode: .simple)
        config.minimumConfidence = .high
        #expect(detect(source, configuration: config).count == 1)

        // Internal declarations are medium confidence; the same source with
        // an internal orphan and a high floor stays silent.
        let internalSource = """
            func orphan() {}
            """
        #expect(detect(internalSource, configuration: config).isEmpty)
    }

    @Test("Disable function detection")
    func disableFunctionDetection() {
        var config = UnusedCodeConfiguration(mode: .simple)
        config.detectFunctions = false

        let findings = detect(
            """
            private func orphan() {}
            private let unusedValue = 1
            """, configuration: config)

        #expect(findings.map(\.declaration.name) == ["unusedValue"])
    }

    @Test("Disable variable detection")
    func disableVariableDetection() {
        var config = UnusedCodeConfiguration(mode: .simple)
        config.detectVariables = false

        let findings = detect(
            """
            private func orphan() {}
            private let unusedValue = 1
            """, configuration: config)

        #expect(findings.map(\.declaration.name) == ["orphan"])
    }

    @Test("Handle empty source")
    func emptySource() {
        #expect(detect("").isEmpty)
    }

    @Test("Handle source with only comments")
    func commentOnlySource() {
        #expect(detect("// nothing here\n/* still nothing */").isEmpty)
    }

    @Test("Handle syntax errors gracefully")
    func syntaxErrors() {
        // The parser is error-tolerant; detection over the recovered tree
        // must not trap.
        let findings = detect(
            """
            private func broken( {
            struct ???
            """)
        _ = findings
    }

    // MARK: - False positive prevention

    @Test("Private method called within same type is not unused")
    func privateMethodCalledInType() {
        let findings = detect(
            """
            struct Machine {
                func run() { step() }
                private func step() {}
            }
            """)

        #expect(findings.isEmpty)
    }

    @Test("Variable used within closure is not unused")
    func variableUsedInClosure() {
        let findings = detect(
            """
            private let factor = 2
            func apply(_ values: [Int]) -> [Int] {
                values.map { $0 * factor }
            }
            """)

        #expect(findings.isEmpty)
    }

    @Test("Struct with @main attribute is not unused")
    func mainStructNotUnused() {
        let findings = detect(
            """
            @main
            private struct App {
                static func main() {}
            }
            """)

        #expect(findings.isEmpty)
    }

    @Test("Function referenced only as a value is not unused")
    func functionReferencedAsValue() {
        let findings = detect(
            """
            private func handler() {}
            let callbacks: [() -> Void] = [handler]
            """)

        #expect(findings.isEmpty)
    }
}
