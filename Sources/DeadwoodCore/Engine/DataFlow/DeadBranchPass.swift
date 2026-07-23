//  New in deadwood: bridges the lifted SCCP machinery to the Analyzer
//  pipeline. Consumes already-parsed trees — SSA re-read and re-parsed
//  every file inside the reachability detector.

import Foundation
import SwiftSyntax

// MARK: - DeadBranchPass

/// Per-file dead-branch detection: walks every function and initializer
/// body, builds a CFG, runs sparse conditional constant propagation, and
/// reports branches whose condition folds to a constant.
enum DeadBranchPass {
    /// Run the pass over one parsed file.
    static func run(tree: SourceFileSyntax, file: String) -> [UnusedCode] {
        let collector = FunctionBodyCollector()
        collector.walk(tree)
        guard !collector.functions.isEmpty || !collector.initializers.isEmpty else {
            return []
        }

        let builder = CFGBuilder(file: file, tree: tree)
        let sccp = SCCPAnalysis()
        var findings: [UnusedCode] = []

        var graphs: [ControlFlowGraph] = []
        for function in collector.functions {
            graphs.append(builder.buildCFG(from: function))
        }
        for initializer in collector.initializers {
            graphs.append(builder.buildCFG(from: initializer))
        }

        for cfg in graphs {
            let result = sccp.analyze(cfg)
            for dead in result.deadBranches {
                findings.append(makeFinding(for: dead, file: file))
            }
        }
        return findings
    }

    /// Wrap a dead branch in the declaration-centric `UnusedCode` shape
    /// with a synthetic declaration at the branch location.
    private static func makeFinding(for dead: DeadBranch, file: String) -> UnusedCode {
        let condition = dead.condition.trimmingCharacters(in: .whitespacesAndNewlines)
        let branchWord = dead.deadBranch == .trueBranch ? "true" : "false"
        let range = SourceRange(start: dead.location, end: dead.location)
        let declaration = Declaration(
            name: "deadBranch(\(condition))",
            kind: .function,
            accessLevel: .internal,
            location: dead.location,
            range: range,
            scope: .global
        )
        return UnusedCode(
            declaration: declaration,
            reason: .deadBranch,
            confidence: .high,
            suggestion:
                "condition '\(condition)' is provably \(dead.conditionValue) — the \(branchWord) branch never executes"
        )
    }
}

// MARK: - FunctionBodyCollector

/// Collects every function and initializer declaration in a parsed tree
/// for the dead-branch pass.
private final class FunctionBodyCollector: SyntaxVisitor {
    private(set) var functions: [FunctionDeclSyntax] = []
    private(set) var initializers: [InitializerDeclSyntax] = []

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        functions.append(node)
        return .visitChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        initializers.append(node)
        return .visitChildren
    }
}
