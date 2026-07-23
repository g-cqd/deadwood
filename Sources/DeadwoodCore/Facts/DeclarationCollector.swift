//  Lifted from SwiftStaticAnalysis (MIT) — Visitors/DeclarationCollector.swift.
//  Changes during the lift:
//  - `swa:ignore` directive extraction removed (deadwood suppression is the
//    `@dw:` directive table applied in the Analyzer).
//  - Enum cases inherit the parent enum's declared access level and its
//    inheritance list, so externally-constructed cases (raw values, Codable,
//    CaseIterable) can be recognized downstream.
//  - Extensions record their conformance list (SSA dropped it), which the
//    witness edges in `DependencyExtractor` rely on.

import Foundation
import SwiftSyntax

// MARK: - DeclarationCollector

/// Collects all declarations from Swift source code.
final class DeclarationCollector: ScopeTrackingVisitor {
    /// Collected declarations.
    private(set) var declarations: [Declaration] = []

    /// Collected imports.
    private(set) var imports: [Declaration] = []

    /// Declared access level of each enclosing enum (for enum cases).
    private var enumContextStack: [(accessLevel: AccessLevel, conformances: [String])] = []

    // MARK: - Functions

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let attrs = extractAttributes(from: node.attributes)
        let signature = extractFunctionSignature(from: node.signature)
        let genericParams = extractGenericParameters(from: node.genericParameterClause)
        let declaration = makeDeclaration(
            name: node.name.text,
            kind: isInTypeContext ? .method : .function,
            modifiers: node.modifiers,
            node: node,
            genericParameters: genericParams,
            signature: signature,
            documentation: extractDocumentation(from: node),
            attributes: attrs
        )
        declarations.append(declaration)

        return super.visit(node)
    }

    // MARK: - Initializers

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        let signature = extractFunctionSignature(from: node.signature)
        let genericParams = extractGenericParameters(from: node.genericParameterClause)
        let declaration = makeDeclaration(
            name: "init",
            kind: .initializer,
            modifiers: node.modifiers,
            node: node,
            genericParameters: genericParams,
            signature: signature,
            documentation: extractDocumentation(from: node)
        )
        declarations.append(declaration)

        return super.visit(node)
    }

    // MARK: - Deinitializers

    override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        let declaration = makeDeclaration(
            name: "deinit",
            kind: .deinitializer,
            modifiers: node.modifiers,
            node: node
        )
        declarations.append(declaration)

        return .visitChildren
    }

    // MARK: - Variables

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let isConstant = node.bindingSpecifier.tokenKind == .keyword(.let)
        let propertyWrappers = extractPropertyWrappers(from: node.attributes)

        for binding in node.bindings {
            guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else {
                continue
            }

            let typeAnnotation = binding.typeAnnotation?.type.description
                .trimmingCharacters(in: .whitespaces)

            let declaration = makeDeclaration(
                name: identifier.identifier.text,
                kind: isConstant ? .constant : .variable,
                modifiers: node.modifiers,
                node: node,
                typeAnnotation: typeAnnotation,
                documentation: extractDocumentation(from: node),
                propertyWrappers: propertyWrappers
            )
            declarations.append(declaration)
        }

        return .visitChildren
    }

    // MARK: - Function parameters

    override func visit(_ node: FunctionParameterSyntax) -> SyntaxVisitorContinueKind {
        let name = node.secondName?.text ?? node.firstName.text

        // Underscore parameters are explicitly unused by design.
        guard name != "_" else {
            return .visitChildren
        }

        let typeAnnotation = node.type.description.trimmingCharacters(in: .whitespaces)

        let declaration = Declaration(
            name: name,
            kind: .parameter,
            accessLevel: .private,
            modifiers: [],
            location: location(of: node),
            range: range(of: node),
            scope: currentScope,
            typeAnnotation: typeAnnotation
        )
        declarations.append(declaration)

        return .visitChildren
    }

    // MARK: - Types

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let conformances = extractConformances(from: node.inheritanceClause)
        let declaration = makeDeclaration(
            name: node.name.text,
            kind: .class,
            modifiers: node.modifiers,
            node: node,
            genericParameters: extractGenericParameters(from: node.genericParameterClause),
            documentation: extractDocumentation(from: node),
            swiftUIInfo: extractSwiftUIInfo(from: conformances),
            conformances: conformances,
            attributes: extractAttributes(from: node.attributes)
        )
        declarations.append(declaration)

        return super.visit(node)
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        let conformances = extractConformances(from: node.inheritanceClause)
        let declaration = makeDeclaration(
            name: node.name.text,
            kind: .struct,
            modifiers: node.modifiers,
            node: node,
            genericParameters: extractGenericParameters(from: node.genericParameterClause),
            documentation: extractDocumentation(from: node),
            swiftUIInfo: extractSwiftUIInfo(from: conformances),
            conformances: conformances,
            attributes: extractAttributes(from: node.attributes)
        )
        declarations.append(declaration)

        return super.visit(node)
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        let conformances = extractConformances(from: node.inheritanceClause)
        let declaration = makeDeclaration(
            name: node.name.text,
            kind: .enum,
            modifiers: node.modifiers,
            node: node,
            genericParameters: extractGenericParameters(from: node.genericParameterClause),
            documentation: extractDocumentation(from: node),
            swiftUIInfo: extractSwiftUIInfo(from: conformances),
            conformances: conformances,
            attributes: extractAttributes(from: node.attributes)
        )
        declarations.append(declaration)

        enumContextStack.append((AccessLevel.from(node.modifiers), conformances))
        return super.visit(node)
    }

    override func visitPost(_ node: EnumDeclSyntax) {
        if !enumContextStack.isEmpty {
            enumContextStack.removeLast()
        }
        super.visitPost(node)
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        let declaration = makeDeclaration(
            name: node.name.text,
            kind: .protocol,
            modifiers: node.modifiers,
            node: node,
            documentation: extractDocumentation(from: node),
            conformances: extractConformances(from: node.inheritanceClause)
        )
        declarations.append(declaration)

        return super.visit(node)
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        let declaration = makeDeclaration(
            name: node.name.text,
            kind: .actor,
            modifiers: node.modifiers,
            node: node,
            genericParameters: extractGenericParameters(from: node.genericParameterClause),
            documentation: extractDocumentation(from: node),
            conformances: extractConformances(from: node.inheritanceClause),
            attributes: extractAttributes(from: node.attributes)
        )
        declarations.append(declaration)

        return super.visit(node)
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.extendedType.description.trimmingCharacters(in: .whitespaces)
        let declaration = makeDeclaration(
            name: name,
            kind: .extension,
            modifiers: node.modifiers,
            node: node,
            conformances: extractConformances(from: node.inheritanceClause)
        )
        declarations.append(declaration)

        return super.visit(node)
    }

    // MARK: - Type aliases

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        let declaration = makeDeclaration(
            name: node.name.text,
            kind: .typealias,
            modifiers: node.modifiers,
            node: node,
            documentation: extractDocumentation(from: node)
        )
        declarations.append(declaration)

        return .visitChildren
    }

    // MARK: - Associated types

    override func visit(_ node: AssociatedTypeDeclSyntax) -> SyntaxVisitorContinueKind {
        let declaration = makeDeclaration(
            name: node.name.text,
            kind: .associatedtype,
            modifiers: node.modifiers,
            node: node,
            documentation: extractDocumentation(from: node)
        )
        declarations.append(declaration)

        return .visitChildren
    }

    // MARK: - Enum cases

    override func visit(_ node: EnumCaseElementSyntax) -> SyntaxVisitorContinueKind {
        let context = enumContextStack.last
        let declaration = Declaration(
            name: node.name.text,
            kind: .enumCase,
            accessLevel: context?.accessLevel ?? .internal,
            modifiers: [],
            location: location(of: node),
            range: range(of: node),
            scope: currentScope,
            conformances: context?.conformances ?? []
        )
        declarations.append(declaration)

        return .visitChildren
    }

    // MARK: - Subscripts

    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        let declaration = makeDeclaration(
            name: "subscript",
            kind: .subscript,
            modifiers: node.modifiers,
            node: node,
            documentation: extractDocumentation(from: node)
        )
        declarations.append(declaration)

        return .visitChildren
    }

    // MARK: - Operators

    override func visit(_ node: OperatorDeclSyntax) -> SyntaxVisitorContinueKind {
        let declaration = Declaration(
            name: node.name.text,
            kind: .operator,
            accessLevel: .internal,
            modifiers: [],
            location: location(of: node),
            range: range(of: node),
            scope: currentScope
        )
        declarations.append(declaration)

        return .visitChildren
    }

    // MARK: - Imports

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        let moduleName = node.path.map(\.name.text).joined(separator: ".")

        let declaration = Declaration(
            name: moduleName,
            kind: .import,
            accessLevel: .internal,
            modifiers: [],
            location: location(of: node),
            range: range(of: node),
            scope: .global
        )
        imports.append(declaration)

        return .visitChildren
    }

    // MARK: - Helpers

    private var isInTypeContext: Bool {
        tracker.tree.chain(from: currentScope).contains { $0.kind.isTypeScope }
    }

    private func makeDeclaration(
        name: String,
        kind: DeclarationKind,
        modifiers: DeclModifierListSyntax,
        node: some SyntaxProtocol,
        typeAnnotation: String? = nil,
        genericParameters: [String] = [],
        signature: FunctionSignature? = nil,
        documentation: String? = nil,
        propertyWrappers: [PropertyWrapperInfo] = [],
        swiftUIInfo: SwiftUITypeInfo? = nil,
        conformances: [String] = [],
        attributes: [String] = []
    ) -> Declaration {
        Declaration(
            name: name,
            kind: kind,
            accessLevel: AccessLevel.from(modifiers),
            modifiers: extractModifiers(from: modifiers),
            location: location(of: node),
            range: range(of: node),
            scope: currentScope,
            typeAnnotation: typeAnnotation,
            genericParameters: genericParameters,
            signature: signature,
            documentation: documentation,
            propertyWrappers: propertyWrappers,
            swiftUIInfo: swiftUIInfo,
            conformances: conformances,
            attributes: attributes
        )
    }

    private func extractModifiers(from modifiers: DeclModifierListSyntax) -> DeclarationModifiers {
        var result: DeclarationModifiers = []

        for modifier in modifiers {
            switch modifier.name.tokenKind {
            case .keyword(.static):
                result.insert(.static)
            case .keyword(.class):
                result.insert(.class)
            case .keyword(.final):
                result.insert(.final)
            case .keyword(.override):
                result.insert(.override)
            case .keyword(.mutating):
                result.insert(.mutating)
            case .keyword(.nonmutating):
                result.insert(.nonmutating)
            case .keyword(.lazy):
                result.insert(.lazy)
            case .keyword(.weak):
                result.insert(.weak)
            case .keyword(.unowned):
                result.insert(.unowned)
            case .keyword(.optional):
                result.insert(.optional)
            case .keyword(.required):
                result.insert(.required)
            case .keyword(.convenience):
                result.insert(.convenience)
            case .keyword(.nonisolated):
                result.insert(.nonisolated)
            case .keyword(.consuming):
                result.insert(.consuming)
            case .keyword(.borrowing):
                result.insert(.borrowing)
            default:
                continue
            }
        }

        return result
    }

    private func extractGenericParameters(from clause: GenericParameterClauseSyntax?) -> [String] {
        guard let clause else { return [] }
        return clause.parameters.map(\.name.text)
    }

    private func extractFunctionSignature(from signature: FunctionSignatureSyntax) -> FunctionSignature {
        let parameters = signature.parameterClause.parameters.map { param in
            let firstName = param.firstName.text
            let secondName = param.secondName?.text

            // With a second name the first is the label, else the first is
            // both. "_" means no external label either way.
            let label: String? = firstName == "_" ? nil : firstName
            let name = secondName ?? firstName

            let type = param.type.description.trimmingCharacters(in: .whitespaces)
            let isInout =
                param.type.as(AttributedTypeSyntax.self)?.specifiers.contains { spec in
                    spec.as(SimpleTypeSpecifierSyntax.self)?.specifier.tokenKind == .keyword(.inout)
                } ?? false

            return FunctionSignature.Parameter(
                label: label,
                name: name,
                type: type,
                hasDefaultValue: param.defaultValue != nil,
                isVariadic: param.ellipsis != nil,
                isInout: isInout
            )
        }

        let returnType = signature.returnClause?.type.description.trimmingCharacters(in: .whitespaces)
        let throwsSpecifier = signature.effectSpecifiers?.throwsClause?.throwsSpecifier

        return FunctionSignature(
            parameters: parameters,
            returnType: returnType,
            isAsync: signature.effectSpecifiers?.asyncSpecifier != nil,
            isThrowing: throwsSpecifier?.tokenKind == .keyword(.throws),
            isRethrowing: throwsSpecifier?.tokenKind == .keyword(.rethrows)
        )
    }

    private func extractDocumentation(from node: some SyntaxProtocol) -> String? {
        for piece in node.leadingTrivia {
            switch piece {
            case .docLineComment(let text):
                return String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)

            case .docBlockComment(let text):
                var cleaned = text
                if cleaned.hasPrefix("/**") {
                    cleaned = String(cleaned.dropFirst(3))
                }
                if cleaned.hasSuffix("*/") {
                    cleaned = String(cleaned.dropLast(2))
                }
                return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

            default:
                continue
            }
        }
        return nil
    }

    // MARK: - Property wrapper extraction

    private func extractPropertyWrappers(from attributes: AttributeListSyntax) -> [PropertyWrapperInfo] {
        var wrappers: [PropertyWrapperInfo] = []

        for element in attributes {
            guard case .attribute(let attribute) = element else {
                continue
            }

            let attributeText = attribute.description.trimmingCharacters(in: .whitespacesAndNewlines)
            let attributeName = name(of: attribute)
            let kind = PropertyWrapperKind(attributeName: attributeName)

            var arguments: String?
            if let args = attribute.arguments {
                arguments = args.description.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            wrappers.append(
                PropertyWrapperInfo(
                    kind: kind,
                    attributeText: attributeText,
                    arguments: arguments
                )
            )
        }

        return wrappers
    }

    // MARK: - Conformance extraction

    private func extractConformances(from inheritanceClause: InheritanceClauseSyntax?) -> [String] {
        guard let clause = inheritanceClause else { return [] }

        return clause.inheritedTypes.map { inheritedType in
            inheritedType.type.description.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func extractSwiftUIInfo(from conformances: [String]) -> SwiftUITypeInfo? {
        var swiftUIConformances: Set<SwiftUIConformance> = []

        for conformance in conformances {
            // Handle qualified names like SwiftUI.View.
            let baseName = conformance.components(separatedBy: ".").last ?? conformance

            if let swiftUIConformance = SwiftUIConformance(rawValue: baseName) {
                swiftUIConformances.insert(swiftUIConformance)
            }
        }

        if swiftUIConformances.isEmpty {
            return nil
        }

        return SwiftUITypeInfo(conformances: swiftUIConformances)
    }

    // MARK: - Attribute extraction

    private func extractAttributes(from attributeList: AttributeListSyntax?) -> [String] {
        guard let attributes = attributeList else { return [] }

        var result: [String] = []

        for element in attributes {
            guard case .attribute(let attribute) = element else {
                continue
            }
            result.append(name(of: attribute))
        }

        return result
    }

    private func name(of attribute: AttributeSyntax) -> String {
        if let identifier = attribute.attributeName.as(IdentifierTypeSyntax.self) {
            identifier.name.text
        } else {
            attribute.attributeName.description
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
