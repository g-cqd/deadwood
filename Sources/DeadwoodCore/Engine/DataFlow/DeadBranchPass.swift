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
    /// Functions above this many statements are skipped and reported as a
    /// degraded-file note instead of analyzed: CFG + SCCP work stays
    /// bounded on adversarial input.
    static let maxStatementsPerFunction = 5000

    /// Findings plus degraded-function notes for one file.
    struct Output: Sendable {
        var findings: [UnusedCode] = []
        /// One human-readable note per function skipped by the statement
        /// bound.
        var degraded: [String] = []
    }

    /// Run the per-function CFG passes over one parsed file, reusing the
    /// file's one `SourceLocationConverter`. Dead branches ride SCCP; dead
    /// stores (opt-in) ride liveness + reaching definitions on the same
    /// CFGs, so enabling both costs one CFG build, not two.
    static func run(
        tree: SourceFileSyntax,
        file: String,
        converter: SourceLocationConverter,
        includeDeadBranches: Bool = true,
        includeDeadStores: Bool = false
    ) -> Output {
        let collector = FunctionBodyCollector()
        collector.walk(tree)
        var output = Output()
        guard !collector.functions.isEmpty || !collector.initializers.isEmpty else {
            return output
        }

        let builder = CFGBuilder(file: file, converter: converter)
        let sccp = SCCPAnalysis()

        var graphs: [ControlFlowGraph] = []
        for (index, function) in collector.functions.enumerated() {
            guard
                withinBound(
                    collector.functionStatementCounts[index],
                    name: function.name.text,
                    output: &output
                )
            else { continue }
            graphs.append(builder.buildCFG(from: function))
        }
        for (index, initializer) in collector.initializers.enumerated() {
            guard
                withinBound(
                    collector.initializerStatementCounts[index],
                    name: "init",
                    output: &output
                )
            else { continue }
            graphs.append(builder.buildCFG(from: initializer))
        }

        for cfg in graphs {
            if includeDeadBranches {
                let result = sccp.analyze(cfg)
                for dead in result.deadBranches {
                    output.findings.append(makeFinding(for: dead, file: file))
                }
            }
            if includeDeadStores {
                output.findings.append(contentsOf: findDeadStores(cfg: cfg, file: file))
            }
        }
        return output
    }

    /// Dead stores: liveness marks assignments never read afterwards;
    /// reaching definitions restrict the report to stores OVERWRITTEN on
    /// every path (a definition still reaching function exit is a "last
    /// write" — unused-variable territory, not a dead store).
    private static func findDeadStores(cfg: ControlFlowGraph, file: String) -> [UnusedCode] {
        let live = LiveVariableAnalysis().analyze(cfg)
        guard !live.deadStores.isEmpty else { return [] }

        let reaching = ReachingDefinitionsAnalysis().analyze(cfg)
        var reachingExit = reaching.reachIn[cfg.exitBlock] ?? []
        for predecessor in cfg.blocks[cfg.exitBlock]?.predecessors ?? [] {
            reachingExit.formUnion(reaching.reachOut[predecessor] ?? [])
        }

        return live.deadStores.compactMap { store -> UnusedCode? in
            let survivesToExit = reachingExit.contains { definition in
                definition.variable == store.variable.name
                    && definition.location == store.location
            }
            guard !survivesToExit else { return nil }
            return makeFinding(for: store, file: file)
        }
    }

    /// Whether a body's statement count (measured during collection — no
    /// extra walk) is inside the bound; records a degraded note when not.
    private static func withinBound(
        _ statementCount: Int,
        name: String,
        output: inout Output
    ) -> Bool {
        guard statementCount > maxStatementsPerFunction else { return true }
        output.degraded.append(
            "function '\(name)' exceeds \(maxStatementsPerFunction) statements — "
                + "dead-branch analysis skipped for it"
        )
        return false
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
            confidence: .certain,
            suggestion:
                "condition '\(condition)' is provably \(dead.conditionValue) — the \(branchWord) branch never executes"
        )
    }

    /// Wrap a dead store in the declaration-centric `UnusedCode` shape
    /// with a synthetic declaration at the store location.
    private static func makeFinding(
        for store: LiveVariableAnalysis.DeadStore,
        file: String
    ) -> UnusedCode {
        let range = SourceRange(start: store.location, end: store.location)
        let declaration = Declaration(
            name: "deadStore(\(store.variable.name))",
            kind: .variable,
            accessLevel: .internal,
            location: store.location,
            range: range,
            scope: .global
        )
        return UnusedCode(
            declaration: declaration,
            reason: .deadStore,
            confidence: .high,
            suggestion:
                "value assigned to '\(store.variable.name)' is overwritten before any read — the store is dead"
        )
    }
}

// MARK: - FunctionBodyCollector

/// Collects every function and initializer declaration in a parsed tree
/// for the dead-branch pass, measuring each one's subtree statement count
/// in the same walk (the adversarial bound needs the count, and a separate
/// counting pass would double the traversal).
private final class FunctionBodyCollector: SyntaxVisitor {
    private(set) var functions: [FunctionDeclSyntax] = []
    private(set) var initializers: [InitializerDeclSyntax] = []

    /// Statement counts aligned with `functions` / `initializers`. A
    /// function's count includes nested bodies (closures, local functions):
    /// the bound caps total CFG work per top-level build.
    private(set) var functionStatementCounts: [Int] = []
    private(set) var initializerStatementCounts: [Int] = []

    /// Open declaration frames: which result array the declaration lives
    /// in, its index there, and the statements counted so far.
    private var frames: [(isFunction: Bool, index: Int, count: Int)] = []

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: CodeBlockItemSyntax) -> SyntaxVisitorContinueKind {
        if !frames.isEmpty {
            frames[frames.count - 1].count += 1
        }
        return .visitChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        functions.append(node)
        functionStatementCounts.append(0)
        frames.append((isFunction: true, index: functions.count - 1, count: 0))
        return .visitChildren
    }

    override func visitPost(_ node: FunctionDeclSyntax) {
        closeFrame()
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        initializers.append(node)
        initializerStatementCounts.append(0)
        frames.append((isFunction: false, index: initializers.count - 1, count: 0))
        return .visitChildren
    }

    override func visitPost(_ node: InitializerDeclSyntax) {
        closeFrame()
    }

    /// Record the finished frame's count and roll it up into the enclosing
    /// frame (a nested function's statements count against its parent's
    /// subtree total too).
    private func closeFrame() {
        guard let frame = frames.popLast() else { return }
        if frame.isFunction {
            functionStatementCounts[frame.index] = frame.count
        } else {
            initializerStatementCounts[frame.index] = frame.count
        }
        if !frames.isEmpty {
            frames[frames.count - 1].count += frame.count
        }
    }
}
