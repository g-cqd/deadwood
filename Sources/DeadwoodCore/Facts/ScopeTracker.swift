//  Lifted from SwiftStaticAnalysis (MIT) — Utilities/ScopeTracker.swift and
//  the syntax-position bridge from Parsing/SwiftFileParser.swift.

import Foundation
import SwiftSyntax

// MARK: - Syntax position bridge

extension AbsolutePosition {
    /// Convert to a `SourceLocation` using a converter.
    func toSourceLocation(
        using converter: SourceLocationConverter,
        file: String
    ) -> SourceLocation {
        let location = converter.location(for: self)
        return SourceLocation(
            file: file,
            line: location.line,
            column: location.column,
            offset: utf8Offset
        )
    }
}

extension SyntaxProtocol {
    /// The source range covered by this node, including trivia-free bounds.
    func sourceRange(
        using converter: SourceLocationConverter,
        file: String
    ) -> SourceRange {
        let start = position.toSourceLocation(using: converter, file: file)
        let end = endPosition.toSourceLocation(using: converter, file: file)
        return SourceRange(start: start, end: end)
    }
}

// MARK: - ScopeTracker

/// Tracks lexical scopes during AST traversal, building a scope tree with
/// unique per-file scope IDs.
struct ScopeTracker: Sendable {
    /// The file being tracked.
    let file: String

    /// The scope tree being built.
    private(set) var tree: ScopeTree

    /// Current scope stack.
    private var scopeStack: [ScopeID]

    /// Counter for generating unique scope IDs.
    private var scopeCounter: Int

    init(file: String) {
        self.file = file
        scopeStack = [.global]
        scopeCounter = 0
        tree = ScopeTree()

        let globalScope = Scope(
            id: .global,
            kind: .global,
            name: nil,
            parent: nil,
            location: SourceLocation(file: file, line: 1, column: 1)
        )
        tree.add(globalScope)
    }

    /// The current scope.
    var currentScope: ScopeID {
        scopeStack.last ?? .global
    }

    /// Enter a new scope.
    @discardableResult
    mutating func enterScope(
        kind: ScopeKind,
        name: String? = nil,
        location: SourceLocation
    ) -> ScopeID {
        scopeCounter += 1
        let scopeID = ScopeID("\(file):\(scopeCounter)")

        let scope = Scope(
            id: scopeID,
            kind: kind,
            name: name,
            parent: currentScope,
            location: location
        )

        tree.add(scope)
        scopeStack.append(scopeID)

        return scopeID
    }

    /// Exit the current scope.
    mutating func exitScope() {
        guard scopeStack.count > 1 else { return }
        scopeStack.removeLast()
    }
}

// MARK: - ScopeTrackingVisitor

/// A syntax visitor that tracks scopes automatically. The collectors
/// subclass this to know the enclosing scope of every node they record.
class ScopeTrackingVisitor: SyntaxVisitor {
    /// The scope tracker.
    var tracker: ScopeTracker

    /// The source location converter, provided by the caller so one file's
    /// line table is built once and shared by every visitor over that file.
    let converter: SourceLocationConverter

    /// The file being visited.
    let file: String

    init(file: String, converter: SourceLocationConverter) {
        self.file = file
        tracker = ScopeTracker(file: file)
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    /// Current scope ID.
    var currentScope: ScopeID {
        tracker.currentScope
    }

    /// Source location of a node, skipping leading trivia so it points at
    /// the declaration itself rather than its comments.
    func location(of node: some SyntaxProtocol) -> SourceLocation {
        node.positionAfterSkippingLeadingTrivia.toSourceLocation(using: converter, file: file)
    }

    /// Source range of a node.
    func range(of node: some SyntaxProtocol) -> SourceRange {
        node.sourceRange(using: converter, file: file)
    }

    // MARK: - Scope-introducing nodes

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        tracker.enterScope(kind: .class, name: node.name.text, location: location(of: node))
        return .visitChildren
    }

    override func visitPost(_ node: ClassDeclSyntax) {
        tracker.exitScope()
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        tracker.enterScope(kind: .struct, name: node.name.text, location: location(of: node))
        return .visitChildren
    }

    override func visitPost(_ node: StructDeclSyntax) {
        tracker.exitScope()
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        tracker.enterScope(kind: .enum, name: node.name.text, location: location(of: node))
        return .visitChildren
    }

    override func visitPost(_ node: EnumDeclSyntax) {
        tracker.exitScope()
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        tracker.enterScope(kind: .protocol, name: node.name.text, location: location(of: node))
        return .visitChildren
    }

    override func visitPost(_ node: ProtocolDeclSyntax) {
        tracker.exitScope()
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        tracker.enterScope(kind: .actor, name: node.name.text, location: location(of: node))
        return .visitChildren
    }

    override func visitPost(_ node: ActorDeclSyntax) {
        tracker.exitScope()
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.extendedType.description.trimmingCharacters(in: .whitespaces)
        tracker.enterScope(kind: .extension, name: name, location: location(of: node))
        return .visitChildren
    }

    override func visitPost(_ node: ExtensionDeclSyntax) {
        tracker.exitScope()
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        tracker.enterScope(kind: .function, name: node.name.text, location: location(of: node))
        return .visitChildren
    }

    override func visitPost(_ node: FunctionDeclSyntax) {
        tracker.exitScope()
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        tracker.enterScope(kind: .function, name: "init", location: location(of: node))
        return .visitChildren
    }

    override func visitPost(_ node: InitializerDeclSyntax) {
        tracker.exitScope()
    }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        tracker.enterScope(kind: .closure, location: location(of: node))
        return .visitChildren
    }

    override func visitPost(_ node: ClosureExprSyntax) {
        tracker.exitScope()
    }

    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        tracker.enterScope(kind: .if, location: location(of: node))
        return .visitChildren
    }

    override func visitPost(_ node: IfExprSyntax) {
        tracker.exitScope()
    }

    override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind {
        tracker.enterScope(kind: .guard, location: location(of: node))
        return .visitChildren
    }

    override func visitPost(_ node: GuardStmtSyntax) {
        tracker.exitScope()
    }

    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        tracker.enterScope(kind: .for, location: location(of: node))
        return .visitChildren
    }

    override func visitPost(_ node: ForStmtSyntax) {
        tracker.exitScope()
    }

    override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind {
        tracker.enterScope(kind: .while, location: location(of: node))
        return .visitChildren
    }

    override func visitPost(_ node: WhileStmtSyntax) {
        tracker.exitScope()
    }

    override func visit(_ node: SwitchExprSyntax) -> SyntaxVisitorContinueKind {
        tracker.enterScope(kind: .switch, location: location(of: node))
        return .visitChildren
    }

    override func visitPost(_ node: SwitchExprSyntax) {
        tracker.exitScope()
    }

    override func visit(_ node: DoStmtSyntax) -> SyntaxVisitorContinueKind {
        tracker.enterScope(kind: .do, location: location(of: node))
        return .visitChildren
    }

    override func visitPost(_ node: DoStmtSyntax) {
        tracker.exitScope()
    }
}
