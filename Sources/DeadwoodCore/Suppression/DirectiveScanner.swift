import SwiftSyntax

/// One token sweep collecting `@dw:`/`@deadwood:` comment directives with
/// their lines.
enum DirectiveScanner {
    static func scan(
        tree: SourceFileSyntax,
        converter: SourceLocationConverter
    ) -> [SuppressionDirective] {
        var directives: [SuppressionDirective] = []

        func scan(_ trivia: Trivia, startingAt startOffset: Int) {
            var offset = startOffset
            for piece in trivia {
                switch piece {
                case .lineComment(let text), .blockComment(let text),
                    .docLineComment(let text), .docBlockComment(let text):
                    let line = converter.location(for: AbsolutePosition(utf8Offset: offset)).line
                    if let directive = SuppressionDirective.parse(comment: text, line: line) {
                        directives.append(directive)
                    }
                default:
                    break
                }
                offset += piece.sourceLength.utf8Length
            }
        }

        for token in tree.tokens(viewMode: .sourceAccurate) {
            scan(token.leadingTrivia, startingAt: token.position.utf8Offset)
            scan(token.trailingTrivia, startingAt: token.endPositionBeforeTrailingTrivia.utf8Offset)
        }
        return directives
    }
}
