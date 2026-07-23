//  Lifted from SwiftStaticAnalysis (MIT) — Visitors/ReferenceCollector.swift.
//  Changes during the lift:
//  - `visit(MacroExpansionExprSyntax)` added so `#selector(...)` and
//    `#keyPath(...)` arguments produce references — a method referenced only
//    via `#selector` is used code (upstream precision gap).

import Foundation
import SwiftSyntax

// MARK: - ReferenceCollector

/// Collects all identifier references from Swift source code, tracking the
/// context in which they appear.
final class ReferenceCollector: ScopeTrackingVisitor {
    /// Collected references.
    private(set) var references: [Reference] = []

    /// Stack tracking the current reference context.
    private var contextStack: [ReferenceContext] = [.unknown]

    private var currentContext: ReferenceContext {
        contextStack.last ?? .unknown
    }

    // MARK: - Identifier expressions

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        let reference = Reference(
            identifier: node.baseName.text,
            location: location(of: node),
            scope: currentScope,
            context: currentContext
        )
        references.append(reference)

        return .visitChildren
    }

    // MARK: - Member access

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        // Track base as member access base.
        if let base = node.base {
            contextStack.append(.memberAccessBase)
            walk(base)
            contextStack.removeLast()
        }

        // Track member name.
        let reference = Reference(
            identifier: node.declName.baseName.text,
            location: location(of: node.declName),
            scope: currentScope,
            context: .memberAccessMember
        )
        references.append(reference)

        return .skipChildren
    }

    // MARK: - Function calls

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        // Track the called expression.
        contextStack.append(.call)
        walk(node.calledExpression)
        contextStack.removeLast()

        // Track arguments normally.
        for argument in node.arguments {
            walk(argument.expression)
        }

        // Track trailing closures (critical for `items.map { ... }`).
        if let trailingClosure = node.trailingClosure {
            walk(trailingClosure)
        }
        for additionalClosure in node.additionalTrailingClosures {
            walk(additionalClosure.closure)
        }

        return .skipChildren
    }

    // MARK: - Macro expansions (#selector, #keyPath, #Preview, ...)

    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        // The macro name itself is a reference (e.g. a custom macro).
        references.append(
            Reference(
                identifier: node.macroName.text,
                location: location(of: node),
                scope: currentScope,
                context: .call
            )
        )

        // Arguments of #selector/#keyPath name declarations that the
        // runtime will invoke: they must count as references. Other macros
        // are treated the same — visiting their arguments is at worst a
        // conservative over-approximation.
        contextStack.append(.call)
        for argument in node.arguments {
            walk(argument.expression)
        }
        contextStack.removeLast()

        if let trailingClosure = node.trailingClosure {
            walk(trailingClosure)
        }
        for additionalClosure in node.additionalTrailingClosures {
            walk(additionalClosure.closure)
        }

        return .skipChildren
    }

    // MARK: - Type annotations

    override func visit(_ node: TypeAnnotationSyntax) -> SyntaxVisitorContinueKind {
        contextStack.append(.typeAnnotation)
        defer { contextStack.removeLast() }
        return .visitChildren
    }

    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        let reference = Reference(
            identifier: node.name.text,
            location: location(of: node),
            scope: currentScope,
            context: currentContext == .unknown ? .typeAnnotation : currentContext
        )
        references.append(reference)

        // Visit generic arguments.
        if let generics = node.genericArgumentClause {
            for argument in generics.arguments {
                walk(argument)
            }
        }

        return .skipChildren
    }

    override func visit(_ node: MemberTypeSyntax) -> SyntaxVisitorContinueKind {
        // Track qualified type: Foo.Bar
        walk(node.baseType)

        let reference = Reference(
            identifier: node.name.text,
            location: location(of: node),
            scope: currentScope,
            context: .typeAnnotation,
            isQualified: true,
            qualifier: node.baseType.description.trimmingCharacters(in: .whitespaces)
        )
        references.append(reference)

        return .skipChildren
    }

    // MARK: - Inheritance

    override func visit(_ node: InheritedTypeSyntax) -> SyntaxVisitorContinueKind {
        contextStack.append(.inheritance)
        defer { contextStack.removeLast() }
        return .visitChildren
    }

    // MARK: - Generic constraints

    override func visit(_ node: GenericWhereClauseSyntax) -> SyntaxVisitorContinueKind {
        contextStack.append(.genericConstraint)
        defer { contextStack.removeLast() }
        return .visitChildren
    }

    // MARK: - Assignments

    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        // Check if this is an assignment. After operator folding, `=` is
        // AssignmentExprSyntax (unfolded trees would show a
        // BinaryOperatorExprSyntax with "=" text instead).
        if node.operator.is(AssignmentExprSyntax.self)
            || node.operator.as(BinaryOperatorExprSyntax.self)?.operator.text == "="
        {
            contextStack.append(.write)
            walk(node.leftOperand)
            contextStack.removeLast()

            contextStack.append(.read)
            walk(node.rightOperand)
            contextStack.removeLast()

            return .skipChildren
        }

        return .visitChildren
    }

    // MARK: - Pattern matching

    override func visit(_ node: ExpressionPatternSyntax) -> SyntaxVisitorContinueKind {
        contextStack.append(.pattern)
        defer { contextStack.removeLast() }
        return .visitChildren
    }

    override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
        // This is a binding, not a reference.
        .skipChildren
    }

    // MARK: - Key paths

    override func visit(_ node: KeyPathExprSyntax) -> SyntaxVisitorContinueKind {
        contextStack.append(.keyPath)
        defer { contextStack.removeLast() }
        return .visitChildren
    }

    // MARK: - Attributes

    override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
        contextStack.append(.attribute)
        defer { contextStack.removeLast() }

        if let identifier = node.attributeName.as(IdentifierTypeSyntax.self) {
            let reference = Reference(
                identifier: identifier.name.text,
                location: location(of: identifier),
                scope: currentScope,
                context: .attribute
            )
            references.append(reference)
        }

        return .visitChildren
    }

    // MARK: - Conditional binding

    override func visit(_ node: OptionalBindingConditionSyntax) -> SyntaxVisitorContinueKind {
        // The pattern is a binding; the initializer is read context.
        if let initializer = node.initializer {
            contextStack.append(.read)
            walk(initializer.value)
            contextStack.removeLast()
        }

        return .skipChildren
    }
}
