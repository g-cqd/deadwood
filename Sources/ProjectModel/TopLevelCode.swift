public import SwiftSyntax

/// A run of code at file scope that is not a declaration: a freestanding
/// macro such as `#Preview`, or statements that execute when the file runs
/// (a script, or `main.swift`). Nothing names such code, so a reference
/// graph built from declarations misses every use made from inside it.
public struct TopLevelCode: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        /// A `#Preview` macro expansion.
        case preview
        /// Any other freestanding macro expansion at file scope.
        case macro
        /// Executable statements or expressions at file scope.
        case statements
    }

    public let kind: Kind
    /// The macro name for `preview` and `macro`; empty for `statements`.
    public let macroName: String
    public let startLine: Int
    public let endLine: Int
    public let region: CodeRegion

    public init(kind: Kind, macroName: String, startLine: Int, endLine: Int, region: CodeRegion) {
        self.kind = kind
        self.macroName = macroName
        self.startLine = startLine
        self.endLine = endLine
        self.region = region
    }
}

/// Finds a file's top-level code, including code nested in `#if` clauses
/// at file scope. Every clause is scanned, active or not.
public enum TopLevelCodeScanner {
    /// - Complexity: O(n) in the number of file-scope items.
    public static func scan(
        _ tree: SourceFileSyntax,
        converter: SourceLocationConverter
    ) -> [TopLevelCode] {
        var found: [TopLevelCode] = []
        scan(tree.statements, region: .production, converter: converter, into: &found)
        return found
    }

    private static func scan(
        _ items: CodeBlockItemListSyntax,
        region: CodeRegion,
        converter: SourceLocationConverter,
        into found: inout [TopLevelCode]
    ) {
        for item in items {
            let kind: TopLevelCode.Kind
            var macroName = ""
            switch item.item {
            case .decl(let declaration):
                if let ifConfig = declaration.as(IfConfigDeclSyntax.self) {
                    scan(ifConfig, region: region, converter: converter, into: &found)
                    continue
                }
                guard let macro = declaration.as(MacroExpansionDeclSyntax.self) else { continue }
                macroName = macro.macroName.text
                kind = macroName == "Preview" ? .preview : .macro
            case .expr(let expression):
                if let macro = expression.as(MacroExpansionExprSyntax.self) {
                    macroName = macro.macroName.text
                    kind = macroName == "Preview" ? .preview : .macro
                } else {
                    kind = .statements
                }
            case .stmt:
                kind = .statements
            }
            let start = converter.location(for: item.positionAfterSkippingLeadingTrivia).line
            let end = converter.location(for: item.endPositionBeforeTrailingTrivia).line
            let itemRegion: CodeRegion =
                switch kind {
                case .preview: region.union(.preview)
                case .statements: region.union(.script)
                case .macro: region
                }
            found.append(
                TopLevelCode(
                    kind: kind, macroName: macroName, startLine: start, endLine: end, region: itemRegion))
        }
    }

    private static func scan(
        _ ifConfig: IfConfigDeclSyntax,
        region: CodeRegion,
        converter: SourceLocationConverter,
        into found: inout [TopLevelCode]
    ) {
        for clause in ifConfig.clauses {
            guard case .statements(let items) = clause.elements else { continue }
            let clauseRegion =
                ConditionalCompilation.isDebugOnly(clause, in: ifConfig)
                ? region.union(.debugOnly) : region
            scan(items, region: clauseRegion, converter: converter, into: &found)
        }
    }
}

/// Reads `#if` conditions without evaluating a build configuration.
public enum ConditionalCompilation {
    /// Whether the clause compiles only when `DEBUG` is set: `#if DEBUG`,
    /// `#elseif DEBUG`, or the `#else` of `#if !DEBUG`.
    public static func isDebugOnly(_ clause: IfConfigClauseSyntax, in ifConfig: IfConfigDeclSyntax) -> Bool {
        if let condition = clause.condition {
            return isDebugFlag(condition)
        }
        // `#else`: debug-only when the clauses before it all test `!DEBUG`.
        let earlier = ifConfig.clauses.prefix { $0.id != clause.id }
        guard !earlier.isEmpty else { return false }
        return earlier.allSatisfy { previous in
            guard let condition = previous.condition?.as(PrefixOperatorExprSyntax.self),
                condition.operator.text == "!"
            else { return false }
            return isDebugFlag(condition.expression)
        }
    }

    private static func isDebugFlag(_ expression: ExprSyntax) -> Bool {
        if let tuple = expression.as(TupleExprSyntax.self), tuple.elements.count == 1,
            let only = tuple.elements.first
        {
            return isDebugFlag(only.expression)
        }
        return expression.as(DeclReferenceExprSyntax.self)?.baseName.text == "DEBUG"
    }
}
