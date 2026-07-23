//  Lifted from SwiftStaticAnalysis (MIT) — the root-detection half of
//  UnusedCodeDetector/Reachability/ReachabilityGraph.swift, extracted into a
//  standalone `RootDetector` so the same semantics drive both the
//  reachability graph and the simple single-file mode.
//
//  Precision additions over SSA:
//  - operator function declarations are roots (`a == b` produces no
//    identifier reference, so flagging `static func ==` was a false positive)
//  - enum cases of raw-value / Codable / CaseIterable enums are roots (they
//    are constructed from outside the source: decoding, allCases, rawValue)
//  - members of types conforming to protocols declared outside the corpus
//    are matched against a catalog of well-known requirement names; types
//    conforming to *unknown* external protocols exempt their non-private
//    members wholesale (they may witness requirements we cannot see)
//  - `override` members are roots (dynamic dispatch through the base)
//  - result-builder members are roots (buildBlock etc. are called by the
//    compiler, not by name)
//  - optional single-file rule: anything effectively visible outside the
//    file is a root, because one file alone cannot prove it unused

// MARK: - RootReason

/// Reasons why a declaration is considered a root (entry point).
enum RootReason: String, Sendable {
    /// Marked with @main.
    case mainAttribute

    /// Marked with @UIApplicationMain.
    case uiApplicationMain

    /// Marked with @NSApplicationMain.
    case nsApplicationMain

    /// Public or open API (may be used externally).
    case publicAPI

    /// Exposed to Objective-C via @objc.
    case objcExposed

    /// Connected via Interface Builder (@IBAction, @IBOutlet, ...).
    case interfaceBuilder

    /// Test method (methods starting with "test", @Test functions).
    case testMethod

    /// Required by Codable synthesis (CodingKeys, coded stored properties).
    case codableRequirement

    /// Main function (non-attribute based).
    case mainFunction

    /// Static main() in a type.
    case staticMain

    /// @dynamicMemberLookup or @dynamicCallable.
    case dynamicFeature

    /// Property-wrapper compiler contract (`wrappedValue`, `projectedValue`):
    /// accessed by wrapper synthesis at every use site, never directly by
    /// name in source.
    case propertyWrapperContract

    /// SwiftUI View type (body property is implicitly used).
    case swiftUIView

    /// SwiftUI App entry point.
    case swiftUIApp

    /// SwiftUI PreviewProvider.
    case swiftUIPreview

    /// SwiftUI property wrapper (@State, @Binding, ...).
    case swiftUIPropertyWrapper

    /// View body property.
    case viewBody

    /// `@_silgen_name` — referenced by mangled name from another
    /// translation unit.
    case silgenName

    /// `@_cdecl` — exposed under a C name for C/Objective-C callers.
    case cdecl

    /// `@_dynamicReplacement(for:)` — resolved through the runtime.
    case dynamicReplacement

    /// `@_objcRuntimeName` — referenced from the Objective-C runtime.
    case objcRuntimeName

    /// Operator function — used through operator syntax, which produces no
    /// identifier reference.
    case operatorFunction

    /// Enum case of a raw-value / Codable / CaseIterable enum — constructed
    /// from outside the source (decoding, `allCases`, `init(rawValue:)`).
    case externallyConstructedCase

    /// Member that may witness a requirement of a protocol declared outside
    /// the corpus, or override an external superclass member.
    case possibleExternalWitness

    /// Member of an @resultBuilder type — called by the compiler, not by name.
    case resultBuilderRequirement

    /// Visible outside the analyzed file (single-file analysis only): one
    /// file cannot prove an internal-or-wider declaration unused.
    case visibleOutsideFile
}

// MARK: - RootDetectionConfiguration

/// Configuration for root detection.
struct RootDetectionConfiguration: Sendable {
    /// Default configuration.
    static let `default` = Self()

    /// Strict configuration (public API is not a root).
    static let strict = Self(treatPublicAsRoot: false)

    /// Treat public/open declarations as roots.
    var treatPublicAsRoot: Bool

    /// Treat @objc declarations as roots.
    var treatObjcAsRoot: Bool

    /// Treat test methods as roots.
    var treatTestsAsRoot: Bool

    /// Treat SwiftUI Views as roots.
    var treatSwiftUIViewsAsRoot: Bool

    /// Treat SwiftUI property wrappers as roots.
    var treatSwiftUIPropertyWrappersAsRoot: Bool

    /// Treat PreviewProviders as roots.
    var treatPreviewProvidersAsRoot: Bool

    /// Treat declarations effectively visible outside their file as roots
    /// (single-file analysis).
    var treatVisibleOutsideFileAsRoot: Bool

    init(
        treatPublicAsRoot: Bool = true,
        treatObjcAsRoot: Bool = true,
        treatTestsAsRoot: Bool = true,
        treatSwiftUIViewsAsRoot: Bool = true,
        treatSwiftUIPropertyWrappersAsRoot: Bool = true,
        treatPreviewProvidersAsRoot: Bool = true,
        treatVisibleOutsideFileAsRoot: Bool = false
    ) {
        self.treatPublicAsRoot = treatPublicAsRoot
        self.treatObjcAsRoot = treatObjcAsRoot
        self.treatTestsAsRoot = treatTestsAsRoot
        self.treatSwiftUIViewsAsRoot = treatSwiftUIViewsAsRoot
        self.treatSwiftUIPropertyWrappersAsRoot = treatSwiftUIPropertyWrappersAsRoot
        self.treatPreviewProvidersAsRoot = treatPreviewProvidersAsRoot
        self.treatVisibleOutsideFileAsRoot = treatVisibleOutsideFileAsRoot
    }
}

// MARK: - ExternalProtocolCatalog

/// Requirement names of well-known protocols that live outside any analyzed
/// corpus (stdlib, Foundation, SwiftUI, ArgumentParser, swift-testing).
/// A member of a type conforming to one of these is a witness only if its
/// name appears here; a type conforming to an *unknown* external protocol
/// exempts all its non-private members (requirements are unknowable).
enum ExternalProtocolCatalog {
    /// `knownRequirements[protocolName]` — member names the conformance uses.
    static let knownRequirements: [String: Set<String>] = [
        "Equatable": ["=="],
        "Hashable": ["hash", "hashValue"],
        "Comparable": ["<", "<=", ">", ">="],
        "Codable": ["init", "encode", "CodingKeys"],
        "Encodable": ["encode", "CodingKeys"],
        "Decodable": ["init", "CodingKeys"],
        "CodingKey": ["stringValue", "intValue", "init"],
        "Error": [],
        "LocalizedError": ["errorDescription", "failureReason", "recoverySuggestion", "helpAnchor"],
        "CustomStringConvertible": ["description"],
        "CustomDebugStringConvertible": ["debugDescription"],
        "Identifiable": ["id", "ID"],
        "RawRepresentable": ["rawValue", "init", "RawValue"],
        "CaseIterable": ["allCases", "AllCases"],
        "Sendable": [],
        "OptionSet": ["rawValue", "init", "RawValue"],
        "Sequence": ["makeIterator", "Iterator", "Element"],
        "IteratorProtocol": ["next", "Element"],
        "AsyncSequence": ["makeAsyncIterator", "AsyncIterator", "Element"],
        "ExpressibleByStringLiteral": ["init"],
        "ExpressibleByIntegerLiteral": ["init"],
        "ExpressibleByArrayLiteral": ["init"],
        "ExpressibleByDictionaryLiteral": ["init"],
        "ExpressibleByNilLiteral": ["init"],
        "ExpressibleByBooleanLiteral": ["init"],
        "ExpressibleByFloatLiteral": ["init"],
        // SwiftUI
        "View": ["body", "Body"],
        "ViewModifier": ["body", "Body"],
        "App": ["body", "Body", "init"],
        "Scene": ["body", "Body"],
        "PreviewProvider": ["previews", "platform"],
        "DynamicProperty": ["update"],
        "EnvironmentKey": ["defaultValue", "Value"],
        "PreferenceKey": ["defaultValue", "reduce", "Value"],
        "ObservableObject": ["objectWillChange", "ObjectWillChangePublisher"],
        // ArgumentParser
        "ParsableCommand": ["configuration", "run", "init"],
        "AsyncParsableCommand": ["configuration", "run", "init"],
        "ParsableArguments": ["init", "validate"],
        "ExpressibleByArgument": ["init", "defaultValueDescription", "allValueStrings"],
    ]

    /// Union of requirement names for the given external protocol names;
    /// nil when any name is unknown (requirements unknowable — exempt all).
    static func requirements(for externalConformances: some Sequence<String>) -> Set<String>? {
        var names: Set<String> = []
        for conformance in externalConformances {
            guard let known = knownRequirements[conformance] else {
                return nil
            }
            names.formUnion(known)
        }
        return names
    }
}

// MARK: - RootDetector

/// Decides whether a declaration is an entry point ("root") and why.
struct RootDetector: Sendable {
    let configuration: RootDetectionConfiguration

    init(configuration: RootDetectionConfiguration = .default) {
        self.configuration = configuration
    }

    /// Determine whether `declaration` is a root and why.
    func rootReason(for declaration: Declaration, context: CorpusContext) -> RootReason? {
        if hasAttribute(declaration, named: "main") {
            return .mainAttribute
        }
        if hasAttribute(declaration, named: "UIApplicationMain") {
            return .uiApplicationMain
        }
        if hasAttribute(declaration, named: "NSApplicationMain") {
            return .nsApplicationMain
        }

        if declaration.name == "main", declaration.kind == .function {
            return .mainFunction
        }
        if declaration.name == "main", declaration.modifiers.contains(.static) {
            return .staticMain
        }

        // Operator declarations and operator functions: usage sites are
        // operator expressions, which produce no identifier reference.
        if declaration.kind == .operator {
            return .operatorFunction
        }
        if declaration.kind == .function || declaration.kind == .method,
            isOperatorName(declaration.name)
        {
            return .operatorFunction
        }

        if configuration.treatPublicAsRoot, context.effectiveAccess(of: declaration) >= .public {
            return .publicAPI
        }

        if configuration.treatObjcAsRoot,
            hasAttribute(declaration, named: "objc") || hasAttribute(declaration, named: "objcMembers")
        {
            return .objcExposed
        }

        if hasAttribute(declaration, named: "IBAction") || hasAttribute(declaration, named: "IBOutlet")
            || hasAttribute(declaration, named: "IBInspectable")
            || hasAttribute(declaration, named: "IBDesignable")
            || hasAttribute(declaration, named: "IBSegueAction")
        {
            return .interfaceBuilder
        }

        if configuration.treatTestsAsRoot {
            let isFunctionLike = declaration.kind == .function || declaration.kind == .method
            if isFunctionLike, declaration.name.hasPrefix("test") {
                return .testMethod
            }
            if isFunctionLike, hasAttribute(declaration, named: "Test") {
                return .testMethod
            }
        }

        if declaration.name == "CodingKeys", declaration.kind == .enum {
            return .codableRequirement
        }

        if hasAttribute(declaration, named: "dynamicMemberLookup")
            || hasAttribute(declaration, named: "dynamicCallable")
        {
            return .dynamicFeature
        }

        // Wrapper synthesis reads these on every wrapper use; a name-level
        // reference never appears in source.
        if declaration.name == "wrappedValue" || declaration.name == "projectedValue" {
            return .propertyWrapperContract
        }

        // Cross-language / runtime attribute roots: referenced through
        // mechanisms invisible to source-level analysis.
        if hasAttribute(declaration, named: "_silgen_name") {
            return .silgenName
        }
        if hasAttribute(declaration, named: "_cdecl") {
            return .cdecl
        }
        if hasAttribute(declaration, named: "_dynamicReplacement") {
            return .dynamicReplacement
        }
        if hasAttribute(declaration, named: "_objcRuntimeName") {
            return .objcRuntimeName
        }

        // SwiftUI roots.
        if configuration.treatSwiftUIViewsAsRoot, declaration.isSwiftUIApp {
            return .swiftUIApp
        }
        if configuration.treatSwiftUIViewsAsRoot, declaration.isSwiftUIView {
            return .swiftUIView
        }
        if configuration.treatPreviewProvidersAsRoot, declaration.isSwiftUIPreview {
            return .swiftUIPreview
        }
        if configuration.treatSwiftUIPropertyWrappersAsRoot, declaration.hasImplicitUsageWrapper {
            return .swiftUIPropertyWrapper
        }
        if configuration.treatSwiftUIViewsAsRoot,
            declaration.name == "body",
            declaration.kind == .variable || declaration.kind == .constant
        {
            return .viewBody
        }

        // Enum cases constructed from outside the source.
        if declaration.kind == .enumCase, isExternallyConstructedCase(declaration) {
            return .externallyConstructedCase
        }

        // Members dispatched invisibly.
        if let reason = memberDispatchRootReason(for: declaration, context: context) {
            return reason
        }

        // Single-file soundness rule.
        if configuration.treatVisibleOutsideFileAsRoot,
            context.effectiveAccess(of: declaration) >= .internal
        {
            return .visibleOutsideFile
        }

        return nil
    }

    // MARK: - Helpers

    /// Raw-value backing types plus conformances that construct or
    /// enumerate cases from outside the source.
    private static let externallyConstructingEnumConformances: Set<String> = [
        "String", "Character", "Int", "Int8", "Int16", "Int32", "Int64",
        "UInt", "UInt8", "UInt16", "UInt32", "UInt64", "Double", "Float",
        "Codable", "Decodable", "Encodable", "CaseIterable", "RawRepresentable",
        "CodingKey",
    ]

    private func isExternallyConstructedCase(_ declaration: Declaration) -> Bool {
        declaration.conformances.contains { conformance in
            Self.externallyConstructingEnumConformances
                .contains(CorpusContext.baseName(ofConformance: conformance))
        }
    }

    /// First character outside identifier-start space means the function is
    /// an operator (`==`, `+`, `<*>`, ...).
    private func isOperatorName(_ name: String) -> Bool {
        guard let first = name.first else { return false }
        return !(first.isLetter || first == "_" || first == "`")
    }

    /// Roots arising from membership: external protocol witnesses, override
    /// members, Codable stored properties, and result-builder members.
    private func memberDispatchRootReason(
        for declaration: Declaration,
        context: CorpusContext
    ) -> RootReason? {
        let memberKinds: Set<DeclarationKind> = [
            .function, .method, .variable, .constant, .subscript, .typealias, .initializer,
            .associatedtype,
        ]
        guard memberKinds.contains(declaration.kind) else { return nil }

        if declaration.modifiers.contains(.override) {
            return .possibleExternalWitness
        }

        if context.isMemberOfType(withAttribute: "resultBuilder", declaration) {
            return .resultBuilderRequirement
        }

        guard let enclosing = context.nearestEnclosingType(of: declaration) else {
            return nil
        }

        let conformances = context.conformances(ofTypeNamed: enclosing.name)
        let external = conformances.filter { !context.protocolNames.contains($0) }
        guard !external.isEmpty else { return nil }

        // Codable synthesis reads/writes every stored property.
        if declaration.kind == .variable || declaration.kind == .constant,
            !external.isDisjoint(with: ["Codable", "Encodable", "Decodable"])
        {
            return .codableRequirement
        }

        // Private members cannot witness protocol requirements.
        guard declaration.accessLevel > .private else { return nil }

        guard let knownNames = ExternalProtocolCatalog.requirements(for: external) else {
            // Unknown external protocol: requirements unknowable, exempt.
            return .possibleExternalWitness
        }
        if knownNames.contains(declaration.name) {
            return .possibleExternalWitness
        }
        return nil
    }

    private func hasAttribute(_ declaration: Declaration, named name: String) -> Bool {
        declaration.attributes.contains(name)
    }
}
