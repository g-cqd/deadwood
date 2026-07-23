//  New in deadwood: bridges the lifted SCCP machinery (stage 2) to the
//  Analyzer pipeline. Consumes already-parsed trees — SSA re-read and
//  re-parsed every file inside the reachability detector.

import SwiftSyntax

// MARK: - DeadBranchPass

/// Per-file dead-branch detection: walks every function and initializer
/// body, builds a CFG, runs sparse conditional constant propagation, and
/// reports branches whose condition folds to a constant.
enum DeadBranchPass {
    /// Run the pass over one parsed file.
    static func run(tree: SourceFileSyntax, file: String) -> [UnusedCode] {
        // Stage 2 (data-flow lift) fills this in; the pipeline seam is
        // wired so the `dead-branch` rule activates the moment SCCP lands.
        []
    }
}
