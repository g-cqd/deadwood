public import SwiftSyntax

/// Lines of one file that belong to a region: `startLine...endLine`.
public struct RegionSpan: Sendable, Hashable {
    public let startLine: Int
    public let endLine: Int
    public let region: CodeRegion

    public init(startLine: Int, endLine: Int, region: CodeRegion) {
        self.startLine = startLine
        self.endLine = endLine
        self.region = region
    }
}

/// Finds the parts of a file that only debug builds or previews compile:
/// `#if DEBUG` clauses at any depth, `#Preview` expansions, and
/// `PreviewProvider` types. Spans may nest or overlap; a line's region is
/// the union of the spans holding it (``RegionSpan/region(atLine:in:)``).
public enum CodeRegionScanner {
    /// - Complexity: O(n) in the number of syntax nodes.
    public static func scan(_ tree: SourceFileSyntax, converter: SourceLocationConverter) -> [RegionSpan] {
        let visitor = Visitor(converter: converter)
        visitor.walk(tree)
        return visitor.spans
    }

    private final class Visitor: SyntaxVisitor {
        let converter: SourceLocationConverter
        var spans: [RegionSpan] = []

        init(converter: SourceLocationConverter) {
            self.converter = converter
            super.init(viewMode: .sourceAccurate)
        }

        private func add(_ node: some SyntaxProtocol, _ region: CodeRegion) {
            let start = converter.location(for: node.positionAfterSkippingLeadingTrivia).line
            let end = converter.location(for: node.endPositionBeforeTrailingTrivia).line
            spans.append(RegionSpan(startLine: start, endLine: end, region: region))
        }

        override func visit(_ node: IfConfigDeclSyntax) -> SyntaxVisitorContinueKind {
            for clause in node.clauses where ConditionalCompilation.isDebugOnly(clause, in: node) {
                add(clause, .debugOnly)
            }
            return .visitChildren
        }

        override func visit(_ node: MacroExpansionDeclSyntax) -> SyntaxVisitorContinueKind {
            if node.macroName.text == "Preview" {
                add(node, .preview)
            }
            return .visitChildren
        }

        override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
            if node.macroName.text == "Preview" {
                add(node, .preview)
            }
            return .visitChildren
        }

        override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
            markPreviewProvider(node, inheritance: node.inheritanceClause)
        }

        override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
            markPreviewProvider(node, inheritance: node.inheritanceClause)
        }

        override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
            markPreviewProvider(node, inheritance: node.inheritanceClause)
        }

        override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
            markPreviewProvider(node, inheritance: node.inheritanceClause)
        }

        private func markPreviewProvider(
            _ node: some SyntaxProtocol,
            inheritance: InheritanceClauseSyntax?
        ) -> SyntaxVisitorContinueKind {
            let names = inheritance?.inheritedTypes.map { $0.type.trimmedDescription } ?? []
            if names.contains(where: { $0 == "PreviewProvider" || $0.hasSuffix(".PreviewProvider") }) {
                add(node, .preview)
            }
            return .visitChildren
        }
    }
}

extension RegionSpan {
    /// The union of the regions of the spans holding `line`.
    /// - Complexity: O(s) in the number of spans.
    public static func region(atLine line: Int, in spans: [RegionSpan]) -> CodeRegion {
        var region = CodeRegion.production
        for span in spans where span.startLine <= line && line <= span.endLine {
            region.formUnion(span.region)
        }
        return region
    }
}
