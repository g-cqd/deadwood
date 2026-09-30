import ProjectModel
import SwiftParser
import SwiftSyntax
import Testing

@Suite struct TopLevelCodeScannerTests {
    private func scan(_ source: String) -> [TopLevelCode] {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: "Sample.swift", tree: tree)
        return TopLevelCodeScanner.scan(tree, converter: converter)
    }

    @Test func `a preview inside #if DEBUG is preview and debug-only code`() {
        let found = scan(
            """
            struct SampleView {}
            #if DEBUG
            #Preview {
                SampleView()
            }
            #endif
            """)

        #expect(
            found == [
                TopLevelCode(
                    kind: .preview, macroName: "Preview", startLine: 3, endLine: 5,
                    region: [.preview, .debugOnly])
            ])
    }

    @Test func `script statements are script code, declarations are not top-level code`() {
        let found = scan(
            """
            func helper() -> Int { 1 }
            let value = helper()
            print(value)
            """)

        #expect(found.map(\.kind) == [.statements])
        #expect(found.map(\.startLine) == [3])
        #expect(found.allSatisfy { $0.region == .script })
    }

    @Test func `the else of #if !DEBUG is debug-only, a plain #else is not`() {
        let found = scan(
            """
            #if !DEBUG
            print("release")
            #else
            print("debug")
            #endif
            #if os(iOS)
            print("device")
            #else
            print("other")
            #endif
            """)

        #expect(found.map(\.region) == [.script, [.script, .debugOnly], .script, .script])
    }

    @Test func `other freestanding macros are top-level code without a region`() {
        let found = scan("#warning(\"later\")\n")

        #expect(found.map(\.kind) == [.macro])
        #expect(found.map(\.macroName) == ["warning"])
        #expect(found.map(\.region) == [.production])
    }
}
