//  New in deadwood. `Parser.parse` leaves `a + b` as a flat
//  `SequenceExprSyntax`; `InfixOperatorExprSyntax` only exists after
//  operator folding. Everything downstream that pattern-matches infix
//  expressions (assignment contexts in the reference collector, constant
//  folding in SCCP) needs the folded tree, so the pipeline folds once,
//  right after parsing.

import SwiftOperators
import SwiftSyntax

/// Fold sequence expressions with the standard operator table. Unknown
/// custom operators are left unfolded (the error handler ignores them);
/// positions are unaffected either way.
func foldedTree(_ tree: SourceFileSyntax) -> SourceFileSyntax {
    let folded = OperatorTable.standardOperators.foldAll(tree) { _ in
        // Unknown operator: leave that subsequence as parsed.
    }
    return folded.as(SourceFileSyntax.self) ?? tree
}
