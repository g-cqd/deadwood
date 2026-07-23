//  Ported from SwiftStaticAnalysis UnusedCodeDetectorTests/RootDetectionTests
//  (adapted: root reasons are asserted on the extracted `RootDetector`
//  rather than through the graph actor), plus the deadwood precision roots.

import Testing

@testable import DeadwoodCore

@Suite("Root Detection")
struct RootDetectionTests {
    private func reason(
        _ declaration: Declaration,
        configuration: RootDetectionConfiguration = .default,
        context: CorpusContext? = nil
    ) -> RootReason? {
        RootDetector(configuration: configuration)
            .rootReason(for: declaration, context: context ?? makeContext([declaration]))
    }

    @Test("Public declarations are roots by default")
    func publicAsRoot() {
        let decl = makeDecl(name: "publicFunction", kind: .function, access: .public)
        #expect(reason(decl) == .publicAPI)
    }

    @Test("Strict mode excludes public API")
    func strictModeExcludesPublic() {
        let decl = makeDecl(name: "publicFunction", kind: .function, access: .public)
        #expect(reason(decl, configuration: .strict) == nil)
    }

    @Test("Test methods are roots")
    func testMethodsAsRoots() {
        let decl = makeDecl(name: "testSomething", kind: .function)
        #expect(reason(decl) == .testMethod)
    }

    @Test("Swift Testing @Test functions are roots")
    func swiftTestingAttributeAsRoot() {
        let decl = makeDecl(name: "parsesEmptyInput", kind: .function, attributes: ["Test"])
        #expect(reason(decl) == .testMethod)
    }

    @Test("Main function is root")
    func mainFunctionAsRoot() {
        let decl = makeDecl(name: "main", kind: .function)
        #expect(reason(decl) == .mainFunction)
    }

    @Test("@main attribute is root")
    func mainAttributeAsRoot() {
        let decl = makeDecl(name: "App", kind: .struct, attributes: ["main"])
        #expect(reason(decl) == .mainAttribute)
    }

    @Test("Static main is root")
    func staticMainAsRoot() {
        let decl = makeDecl(name: "main", kind: .method, modifiers: [.static])
        #expect(reason(decl) != nil)
    }

    @Test("@objc declarations are roots")
    func objcAsRoot() {
        let decl = makeDecl(name: "handleTap", kind: .method, access: .private, attributes: ["objc"])
        #expect(reason(decl) == .objcExposed)
    }

    @Test("Interface Builder attributes are roots")
    func interfaceBuilderAsRoot() {
        let decl = makeDecl(
            name: "didTapButton", kind: .method, access: .private, attributes: ["IBAction"])
        // @objc check runs first for IBAction-annotated members without
        // @objc; the reason must be one of the two runtime-exposure kinds.
        #expect([RootReason.interfaceBuilder, .objcExposed].contains(reason(decl)))
    }

    @Test("CodingKeys enums are roots")
    func codingKeysAsRoot() {
        let decl = makeDecl(name: "CodingKeys", kind: .enum, access: .private)
        #expect(reason(decl) == .codableRequirement)
    }

    @Test("Cross-language attributes are roots")
    func crossLanguageAttributesAsRoots() {
        #expect(
            reason(makeDecl(name: "f", kind: .function, access: .private, attributes: ["_silgen_name"]))
                == .silgenName)
        #expect(
            reason(makeDecl(name: "g", kind: .function, access: .private, attributes: ["_cdecl"]))
                == .cdecl)
        #expect(
            reason(
                makeDecl(
                    name: "h", kind: .function, access: .private,
                    attributes: ["_dynamicReplacement"]))
                == .dynamicReplacement)
    }

    // MARK: - Precision roots added during the lift

    @Test("Operator functions are roots")
    func operatorFunctionsAsRoots() {
        let equals = makeDecl(name: "==", kind: .method, modifiers: [.static])
        let plus = makeDecl(name: "+", kind: .function, access: .private)
        let custom = makeDecl(name: "<*>", kind: .function, access: .fileprivate)

        #expect(reason(equals) == .operatorFunction)
        #expect(reason(plus) == .operatorFunction)
        #expect(reason(custom) == .operatorFunction)
    }

    @Test("Regular names are not operator roots")
    func regularNamesNotOperatorRoots() {
        let decl = makeDecl(name: "compute", kind: .function, access: .private)
        #expect(reason(decl) == nil)
    }

    @Test("Raw-value enum cases are roots")
    func rawValueEnumCasesAsRoots() {
        let rawCase = makeDecl(
            name: "active", kind: .enumCase, access: .private, conformances: ["String", "Codable"])
        #expect(reason(rawCase) == .externallyConstructedCase)

        let caseIterable = makeDecl(
            name: "north", kind: .enumCase, access: .private, conformances: ["CaseIterable"])
        #expect(reason(caseIterable) == .externallyConstructedCase)
    }

    @Test("Plain enum cases are not externally constructed")
    func plainEnumCasesNotRoots() {
        let plainCase = makeDecl(name: "fast", kind: .enumCase, access: .private)
        #expect(reason(plainCase) == nil)
    }

    @Test("Override members are roots")
    func overrideMembersAsRoots() {
        let decl = makeDecl(name: "viewDidLoad", kind: .method, modifiers: [.override])
        #expect(reason(decl) == .possibleExternalWitness)
    }

    @Test("SwiftUI property wrappers are roots")
    func swiftUIPropertyWrapperAsRoot() {
        let location = SourceLocation(file: "test.swift", line: 1, column: 1)
        let decl = Declaration(
            name: "count",
            kind: .variable,
            accessLevel: .private,
            location: location,
            range: SourceRange(start: location, end: location),
            scope: .global,
            propertyWrappers: [PropertyWrapperInfo(kind: .state, attributeText: "@State")]
        )
        #expect(reason(decl) == .swiftUIPropertyWrapper)
    }

    @Test("Visible-outside-file rule fires only when enabled")
    func visibleOutsideFileRule() {
        let decl = makeDecl(name: "helper", kind: .function, access: .internal)

        #expect(reason(decl) == nil)

        var config = RootDetectionConfiguration()
        config.treatVisibleOutsideFileAsRoot = true
        #expect(reason(decl, configuration: config) == .visibleOutsideFile)

        let privateDecl = makeDecl(name: "secret", kind: .function, access: .private)
        #expect(reason(privateDecl, configuration: config) == nil)
    }

    @Test("Known external witness names are roots; unknown members are not")
    func externalWitnessCatalog() {
        let source = """
            struct Wrapper: CustomStringConvertible {
                var description: String { "w" }
                func helperNobodyCalls() {}
            }
            """
        let result = makeFacts(source)
        let context = CorpusContext(result: result)
        let detector = RootDetector(configuration: .default)

        let description = result.declarations.declarations.first { $0.name == "description" }!
        let helper = result.declarations.declarations.first { $0.name == "helperNobodyCalls" }!

        #expect(detector.rootReason(for: description, context: context) == .possibleExternalWitness)
        #expect(detector.rootReason(for: helper, context: context) == nil)
    }

    @Test("Unknown external protocol exempts non-private members")
    func unknownExternalProtocolExemptsMembers() {
        let source = """
            final class Worker: SomeVendorDelegate {
                func vendorDidFinish() {}
                private func trulyPrivate() {}
            }
            """
        let result = makeFacts(source)
        let context = CorpusContext(result: result)
        let detector = RootDetector(configuration: .default)

        let callback = result.declarations.declarations.first { $0.name == "vendorDidFinish" }!
        let secret = result.declarations.declarations.first { $0.name == "trulyPrivate" }!

        #expect(detector.rootReason(for: callback, context: context) == .possibleExternalWitness)
        #expect(detector.rootReason(for: secret, context: context) == nil)
    }

    @Test("Codable stored properties are roots")
    func codableStoredPropertiesAsRoots() {
        let source = """
            struct Payload: Codable {
                let token: String
            }
            """
        let result = makeFacts(source)
        let context = CorpusContext(result: result)
        let detector = RootDetector(configuration: .default)

        let token = result.declarations.declarations.first { $0.name == "token" }!
        #expect(detector.rootReason(for: token, context: context) == .codableRequirement)
    }
}
