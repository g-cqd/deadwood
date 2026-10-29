import Suppression
import SwiftSyntax

/// Prefix-specific facade over analyzerkit's prefiltered comment sweep.
enum DirectiveScanner {
    static func scan(tree: SourceFileSyntax, converter: SourceLocationConverter) -> [SuppressionDirective] {
        SuppressionDirective.grammar.scan(tree: tree, converter: converter, parse: SuppressionDirective.parse)
    }
}
