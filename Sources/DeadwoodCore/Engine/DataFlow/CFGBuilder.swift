//  Lifted from SwiftStaticAnalysis (MIT) — UnusedCodeDetector/DataFlow/CFGBuilder.swift.

import Foundation
import SwiftSyntax

// MARK: - VariableID

/// A unique identifier for a variable that includes scope context, so
/// shadowed variables in nested blocks stay distinguishable.
struct VariableID: Hashable, Sendable, CustomStringConvertible, Comparable {
    /// The variable name.
    let name: String

    /// The scope nesting depth (0 = function level).
    let scopeDepth: Int

    /// The line where this variable was declared (if known).
    let declarationLine: Int?

    init(name: String, scopeDepth: Int = 0, declarationLine: Int? = nil) {
        self.name = name
        self.scopeDepth = scopeDepth
        self.declarationLine = declarationLine
    }

    var description: String {
        if let line = declarationLine {
            return "\(name)@\(scopeDepth):\(line)"
        }
        return "\(name)@\(scopeDepth)"
    }

    static func < (lhs: VariableID, rhs: VariableID) -> Bool {
        if lhs.name != rhs.name {
            return lhs.name < rhs.name
        }
        if lhs.scopeDepth != rhs.scopeDepth {
            return lhs.scopeDepth < rhs.scopeDepth
        }
        return (lhs.declarationLine ?? 0) < (rhs.declarationLine ?? 0)
    }
}

// MARK: - BlockID

/// A unique identifier for a basic block.
struct BlockID: Hashable, Sendable, CustomStringConvertible {
    static let entry = Self("entry")
    static let exit = Self("exit")

    let value: String

    init(_ value: String) {
        self.value = value
    }

    var description: String { value }
}

// MARK: - CFGStatement

/// A statement in the CFG with its source location and use/def sets.
struct CFGStatement: Sendable {
    /// The syntax node.
    let syntax: Syntax

    /// Source location.
    let location: SourceLocation

    /// Variables read by the statement.
    let uses: Set<VariableID>

    /// Variables written by the statement.
    let defs: Set<VariableID>

    init(
        syntax: Syntax,
        location: SourceLocation,
        uses: Set<VariableID>,
        defs: Set<VariableID>
    ) {
        self.syntax = syntax
        self.location = location
        self.uses = uses
        self.defs = defs
    }

    /// The trimmed source text when it fits within `maxLength` characters;
    /// nil otherwise. The data-flow passes capture the RHS of small
    /// assignments as an opaque string.
    func shortDescription(maxLength: Int) -> String? {
        let text = syntax.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count < maxLength ? text : nil
    }
}

// MARK: - Terminator

/// A terminator instruction for a basic block.
enum Terminator: Sendable {
    /// Unconditional branch to another block.
    case branch(BlockID)

    /// Conditional branch based on a condition.
    case conditionalBranch(condition: String, trueTarget: BlockID, falseTarget: BlockID)

    /// Switch statement with multiple targets.
    case `switch`(expression: String, cases: [(pattern: String, target: BlockID)], default: BlockID?)

    /// Return from function.
    case `return`(expression: String?)

    /// Throw an error.
    case `throw`(expression: String)

    /// Fall through to the next case block.
    case `fallthrough`(BlockID)

    /// Break from loop or switch.
    case `break`(target: BlockID?)

    /// Continue to next loop iteration.
    case `continue`(target: BlockID?)

    /// Unreachable (after fatalError and friends).
    case unreachable
}

// MARK: - BasicBlock

/// A basic block in the control flow graph.
struct BasicBlock: Identifiable, Sendable {
    /// Unique identifier.
    let id: BlockID

    /// Statements in this block (in order).
    var statements: [CFGStatement]

    /// The terminator instruction.
    var terminator: Terminator?

    /// Successor block IDs.
    var successors: [BlockID]

    /// Predecessor block IDs.
    var predecessors: [BlockID]

    /// Variables used before being defined in this block.
    var use: Set<VariableID>

    /// Variables defined in this block.
    var def: Set<VariableID>

    /// Live variables at block entry (computed by analysis).
    var liveIn: Set<VariableID>

    /// Live variables at block exit (computed by analysis).
    var liveOut: Set<VariableID>

    /// Whether this block carries a loop condition. `while true { ... }`
    /// intentionally never takes its exit edge — the dead-branch pass must
    /// not flag the infinite-loop idiom.
    var isLoopHeader: Bool

    init(id: BlockID) {
        self.id = id
        statements = []
        terminator = nil
        successors = []
        predecessors = []
        use = []
        def = []
        liveIn = []
        liveOut = []
        isLoopHeader = false
    }
}

// MARK: - ControlFlowGraph

/// Control flow graph for one function body.
struct ControlFlowGraph: Sendable {
    /// All basic blocks indexed by ID.
    var blocks: [BlockID: BasicBlock]

    /// Entry block ID.
    let entryBlock: BlockID

    /// Exit block ID.
    let exitBlock: BlockID

    /// Function name.
    let functionName: String

    /// Source file.
    let file: String

    /// Block order for iteration (insertion order).
    var blockOrder: [BlockID]

    /// Reverse postorder for efficient iteration.
    var reversePostOrder: [BlockID]

    init(functionName: String, file: String) {
        self.functionName = functionName
        self.file = file
        entryBlock = .entry
        exitBlock = .exit
        blocks = [
            .entry: BasicBlock(id: .entry),
            .exit: BasicBlock(id: .exit),
        ]
        blockOrder = [.entry]
        reversePostOrder = []
    }

    /// Add a block to the CFG.
    mutating func addBlock(_ block: BasicBlock) {
        blocks[block.id] = block
        blockOrder.append(block.id)
    }

    /// Add an edge between blocks.
    mutating func addEdge(from: BlockID, to: BlockID) {
        blocks[from]?.successors.append(to)
        blocks[to]?.predecessors.append(from)
    }

    /// Compute the reverse postorder traversal from the entry block.
    mutating func computeReversePostOrder() {
        var visited = Set<BlockID>()
        var postOrder: [BlockID] = []

        func dfs(_ blockID: BlockID) {
            guard !visited.contains(blockID) else { return }
            visited.insert(blockID)

            if let block = blocks[blockID] {
                for successor in block.successors {
                    dfs(successor)
                }
            }
            postOrder.append(blockID)
        }

        dfs(entryBlock)
        reversePostOrder = postOrder.reversed()
    }
}

// MARK: - CFGBuilder

/// Builds a control flow graph from Swift function declarations.
final class CFGBuilder: SyntaxVisitor {
    /// Source location converter.
    private let converter: SourceLocationConverter

    /// File path.
    private let file: String

    /// Current CFG being built.
    private var cfg: ControlFlowGraph

    /// Current block being populated.
    private var currentBlockID: BlockID

    /// Block counter for generating unique IDs.
    private var blockCounter: Int = 0

    /// Stack of loop headers for break/continue.
    private var loopStack: [(header: BlockID, exit: BlockID, id: String)] = []

    /// Stack of switch exit blocks.
    private var switchStack: [BlockID] = []

    /// Pending block connections (do/catch exception flow).
    private var pendingConnections: [(from: BlockID, to: BlockID)] = []

    init(file: String, converter: SourceLocationConverter) {
        self.file = file
        self.converter = converter
        cfg = ControlFlowGraph(functionName: "", file: file)
        currentBlockID = .entry
        super.init(viewMode: .sourceAccurate)
    }

    /// Build a CFG for a function declaration.
    func buildCFG(from function: FunctionDeclSyntax) -> ControlFlowGraph {
        resetAndBuild(name: function.name.text) {
            if let body = function.body {
                self.processCodeBlock(body)
            }
        }
    }

    /// Build a CFG for an initializer declaration.
    func buildCFG(from initializer: InitializerDeclSyntax) -> ControlFlowGraph {
        resetAndBuild(name: "init") {
            if let body = initializer.body {
                self.processCodeBlock(body)
            }
        }
    }

    // MARK: - Private

    private func resetAndBuild(name: String, bodyProcessor: () -> Void) -> ControlFlowGraph {
        cfg = ControlFlowGraph(functionName: name, file: file)
        currentBlockID = .entry
        blockCounter = 0
        loopStack = []
        switchStack = []
        pendingConnections = []

        bodyProcessor()

        // Connect the current block to exit if not already terminated.
        if cfg.blocks[currentBlockID]?.terminator == nil {
            cfg.addEdge(from: currentBlockID, to: .exit)
            cfg.blocks[currentBlockID]?.terminator = .return(expression: nil)
        }

        for (from, to) in pendingConnections {
            cfg.addEdge(from: from, to: to)
        }

        cfg.computeReversePostOrder()
        computeUseDef()

        return cfg
    }

    // MARK: - Block management

    private func newBlock() -> BlockID {
        blockCounter += 1
        let id = BlockID("block_\(blockCounter)")
        cfg.addBlock(BasicBlock(id: id))
        return id
    }

    private func switchToBlock(_ id: BlockID) {
        currentBlockID = id
    }

    // MARK: - Statement processing

    private func processCodeBlock(_ block: CodeBlockSyntax) {
        for statement in block.statements {
            processStatement(statement.item)
        }
    }

    private func processStatement(_ item: CodeBlockItemSyntax.Item) {
        switch item {
        case .stmt(let stmt):
            processStmt(stmt)

        case .decl(let decl):
            addStatementToCurrentBlock(Syntax(decl))

        case .expr(let expr):
            // If/switch expressions used as statements still branch.
            if let ifExpr = expr.as(IfExprSyntax.self) {
                processIfStatement(ifExpr)
            } else if let switchExpr = expr.as(SwitchExprSyntax.self) {
                processSwitchStatement(switchExpr)
            } else {
                addStatementToCurrentBlock(Syntax(expr))
            }
        }
    }

    private func processStmt(_ stmt: StmtSyntax) {
        if let exprStmt = stmt.as(ExpressionStmtSyntax.self) {
            if let ifExpr = exprStmt.expression.as(IfExprSyntax.self) {
                processIfStatement(ifExpr)
                return
            } else if let switchExpr = exprStmt.expression.as(SwitchExprSyntax.self) {
                processSwitchStatement(switchExpr)
                return
            }
        }

        if let guardStmt = stmt.as(GuardStmtSyntax.self) {
            processGuardStatement(guardStmt)
        } else if let forStmt = stmt.as(ForStmtSyntax.self) {
            processForStatement(forStmt)
        } else if let whileStmt = stmt.as(WhileStmtSyntax.self) {
            processWhileStatement(whileStmt)
        } else if let repeatStmt = stmt.as(RepeatStmtSyntax.self) {
            processRepeatWhileStatement(repeatStmt)
        } else if let returnStmt = stmt.as(ReturnStmtSyntax.self) {
            processReturnStatement(returnStmt)
        } else if let throwStmt = stmt.as(ThrowStmtSyntax.self) {
            processThrowStatement(throwStmt)
        } else if let breakStmt = stmt.as(BreakStmtSyntax.self) {
            processBreakStatement(breakStmt)
        } else if let continueStmt = stmt.as(ContinueStmtSyntax.self) {
            processContinueStatement(continueStmt)
        } else if let fallthroughStmt = stmt.as(FallThroughStmtSyntax.self) {
            processFallthroughStatement(fallthroughStmt)
        } else if let doStmt = stmt.as(DoStmtSyntax.self) {
            processDoStatement(doStmt)
        } else {
            addStatementToCurrentBlock(Syntax(stmt))
        }
    }

    // MARK: - Control flow statements

    private func processIfStatement(_ ifStmt: IfExprSyntax) {
        let conditionText = ifStmt.conditions.description
        addStatementToCurrentBlock(Syntax(ifStmt.conditions))

        let thenBlock = newBlock()
        let elseBlock = newBlock()
        let mergeBlock = newBlock()

        cfg.blocks[currentBlockID]?.terminator = .conditionalBranch(
            condition: conditionText,
            trueTarget: thenBlock,
            falseTarget: elseBlock
        )
        cfg.addEdge(from: currentBlockID, to: thenBlock)
        cfg.addEdge(from: currentBlockID, to: elseBlock)

        switchToBlock(thenBlock)
        processCodeBlock(ifStmt.body)
        if cfg.blocks[currentBlockID]?.terminator == nil {
            cfg.addEdge(from: currentBlockID, to: mergeBlock)
            cfg.blocks[currentBlockID]?.terminator = .branch(mergeBlock)
        }

        switchToBlock(elseBlock)
        if let elseBody = ifStmt.elseBody {
            switch elseBody {
            case .codeBlock(let block):
                processCodeBlock(block)

            case .ifExpr(let elseIf):
                processIfStatement(elseIf)
            }
        }
        if cfg.blocks[currentBlockID]?.terminator == nil {
            cfg.addEdge(from: currentBlockID, to: mergeBlock)
            cfg.blocks[currentBlockID]?.terminator = .branch(mergeBlock)
        }

        switchToBlock(mergeBlock)
    }

    private func processGuardStatement(_ guardStmt: GuardStmtSyntax) {
        let conditionText = guardStmt.conditions.description
        addStatementToCurrentBlock(Syntax(guardStmt.conditions))

        let elseBlock = newBlock()
        let continueBlock = newBlock()

        cfg.blocks[currentBlockID]?.terminator = .conditionalBranch(
            condition: conditionText,
            trueTarget: continueBlock,
            falseTarget: elseBlock
        )
        cfg.addEdge(from: currentBlockID, to: continueBlock)
        cfg.addEdge(from: currentBlockID, to: elseBlock)

        switchToBlock(elseBlock)
        processCodeBlock(guardStmt.body)
        // Guard else must exit scope; recover gracefully if it doesn't.
        if cfg.blocks[currentBlockID]?.terminator == nil {
            cfg.addEdge(from: currentBlockID, to: .exit)
            cfg.blocks[currentBlockID]?.terminator = .unreachable
        }

        switchToBlock(continueBlock)
    }

    private func processForStatement(_ forStmt: ForStmtSyntax) {
        let loopID = "loop_\(blockCounter)"
        let headerBlock = newBlock()
        let bodyBlock = newBlock()
        let exitBlock = newBlock()

        cfg.addEdge(from: currentBlockID, to: headerBlock)
        cfg.blocks[currentBlockID]?.terminator = .branch(headerBlock)

        switchToBlock(headerBlock)
        cfg.blocks[headerBlock]?.isLoopHeader = true
        addStatementToCurrentBlock(Syntax(forStmt.sequence))
        cfg.blocks[headerBlock]?.terminator = .conditionalBranch(
            condition: "for \(forStmt.pattern.description) in \(forStmt.sequence.description)",
            trueTarget: bodyBlock,
            falseTarget: exitBlock
        )
        cfg.addEdge(from: headerBlock, to: bodyBlock)
        cfg.addEdge(from: headerBlock, to: exitBlock)

        loopStack.append((header: headerBlock, exit: exitBlock, id: loopID))

        switchToBlock(bodyBlock)
        processCodeBlock(forStmt.body)
        if cfg.blocks[currentBlockID]?.terminator == nil {
            cfg.addEdge(from: currentBlockID, to: headerBlock)
            cfg.blocks[currentBlockID]?.terminator = .branch(headerBlock)
        }

        loopStack.removeLast()
        switchToBlock(exitBlock)
    }

    private func processWhileStatement(_ whileStmt: WhileStmtSyntax) {
        let loopID = "loop_\(blockCounter)"
        let headerBlock = newBlock()
        let bodyBlock = newBlock()
        let exitBlock = newBlock()

        cfg.addEdge(from: currentBlockID, to: headerBlock)
        cfg.blocks[currentBlockID]?.terminator = .branch(headerBlock)

        switchToBlock(headerBlock)
        cfg.blocks[headerBlock]?.isLoopHeader = true
        let conditionText = whileStmt.conditions.description
        addStatementToCurrentBlock(Syntax(whileStmt.conditions))
        cfg.blocks[headerBlock]?.terminator = .conditionalBranch(
            condition: conditionText,
            trueTarget: bodyBlock,
            falseTarget: exitBlock
        )
        cfg.addEdge(from: headerBlock, to: bodyBlock)
        cfg.addEdge(from: headerBlock, to: exitBlock)

        loopStack.append((header: headerBlock, exit: exitBlock, id: loopID))

        switchToBlock(bodyBlock)
        processCodeBlock(whileStmt.body)
        if cfg.blocks[currentBlockID]?.terminator == nil {
            cfg.addEdge(from: currentBlockID, to: headerBlock)
            cfg.blocks[currentBlockID]?.terminator = .branch(headerBlock)
        }

        loopStack.removeLast()
        switchToBlock(exitBlock)
    }

    private func processRepeatWhileStatement(_ repeatStmt: RepeatStmtSyntax) {
        let loopID = "loop_\(blockCounter)"
        let bodyBlock = newBlock()
        let conditionBlock = newBlock()
        let exitBlock = newBlock()

        cfg.addEdge(from: currentBlockID, to: bodyBlock)
        cfg.blocks[currentBlockID]?.terminator = .branch(bodyBlock)

        loopStack.append((header: bodyBlock, exit: exitBlock, id: loopID))

        switchToBlock(bodyBlock)
        processCodeBlock(repeatStmt.body)
        if cfg.blocks[currentBlockID]?.terminator == nil {
            cfg.addEdge(from: currentBlockID, to: conditionBlock)
            cfg.blocks[currentBlockID]?.terminator = .branch(conditionBlock)
        }

        loopStack.removeLast()

        switchToBlock(conditionBlock)
        cfg.blocks[conditionBlock]?.isLoopHeader = true
        let conditionText = repeatStmt.condition.description
        addStatementToCurrentBlock(Syntax(repeatStmt.condition))
        cfg.blocks[conditionBlock]?.terminator = .conditionalBranch(
            condition: conditionText,
            trueTarget: bodyBlock,
            falseTarget: exitBlock
        )
        cfg.addEdge(from: conditionBlock, to: bodyBlock)
        cfg.addEdge(from: conditionBlock, to: exitBlock)

        switchToBlock(exitBlock)
    }

    private func processSwitchStatement(_ switchStmt: SwitchExprSyntax) {
        let exitBlock = newBlock()
        switchStack.append(exitBlock)

        addStatementToCurrentBlock(Syntax(switchStmt.subject))

        var caseBlocks: [(pattern: String, target: BlockID)] = []
        var defaultBlock: BlockID?

        for caseItem in switchStmt.cases {
            switch caseItem {
            case .switchCase(let switchCase):
                let caseBlock = newBlock()
                if let label = switchCase.label.as(SwitchCaseLabelSyntax.self) {
                    caseBlocks.append((pattern: label.caseItems.description, target: caseBlock))
                } else if switchCase.label.is(SwitchDefaultLabelSyntax.self) {
                    defaultBlock = caseBlock
                }

            case .ifConfigDecl:
                break
            }
        }

        cfg.blocks[currentBlockID]?.terminator = .switch(
            expression: switchStmt.subject.description,
            cases: caseBlocks,
            default: defaultBlock
        )

        for (_, target) in caseBlocks {
            cfg.addEdge(from: currentBlockID, to: target)
        }
        if let defaultBlock {
            cfg.addEdge(from: currentBlockID, to: defaultBlock)
        }

        for caseItem in switchStmt.cases {
            switch caseItem {
            case .switchCase(let switchCase):
                let caseBlock: BlockID
                if let label = switchCase.label.as(SwitchCaseLabelSyntax.self) {
                    let pattern = label.caseItems.description
                    caseBlock = caseBlocks.first { $0.pattern == pattern }?.target ?? newBlock()
                } else if switchCase.label.is(SwitchDefaultLabelSyntax.self) {
                    caseBlock = defaultBlock ?? newBlock()
                } else {
                    continue
                }

                switchToBlock(caseBlock)
                for statement in switchCase.statements {
                    processStatement(statement.item)
                }

                if cfg.blocks[currentBlockID]?.terminator == nil {
                    cfg.addEdge(from: currentBlockID, to: exitBlock)
                    cfg.blocks[currentBlockID]?.terminator = .branch(exitBlock)
                }

            case .ifConfigDecl:
                break
            }
        }

        switchStack.removeLast()
        switchToBlock(exitBlock)
    }

    private func processReturnStatement(_ returnStmt: ReturnStmtSyntax) {
        addStatementToCurrentBlock(Syntax(returnStmt))
        cfg.addEdge(from: currentBlockID, to: .exit)
        cfg.blocks[currentBlockID]?.terminator = .return(
            expression: returnStmt.expression?.description
        )
    }

    private func processThrowStatement(_ throwStmt: ThrowStmtSyntax) {
        addStatementToCurrentBlock(Syntax(throwStmt))
        cfg.addEdge(from: currentBlockID, to: .exit)
        cfg.blocks[currentBlockID]?.terminator = .throw(
            expression: throwStmt.expression.description
        )
    }

    private func processBreakStatement(_ breakStmt: BreakStmtSyntax) {
        addStatementToCurrentBlock(Syntax(breakStmt))

        let target: BlockID? =
            if let label = breakStmt.label {
                loopStack.first { $0.id == label.text }?.exit ?? switchStack.last
            } else if !switchStack.isEmpty {
                switchStack.last
            } else if let loop = loopStack.last {
                loop.exit
            } else {
                nil
            }

        if let target {
            cfg.addEdge(from: currentBlockID, to: target)
        }
        cfg.blocks[currentBlockID]?.terminator = .break(target: target)
    }

    private func processContinueStatement(_ continueStmt: ContinueStmtSyntax) {
        addStatementToCurrentBlock(Syntax(continueStmt))

        let target: BlockID? =
            if let label = continueStmt.label {
                loopStack.first { $0.id == label.text }?.header
            } else {
                loopStack.last?.header
            }

        if let target {
            cfg.addEdge(from: currentBlockID, to: target)
        }
        cfg.blocks[currentBlockID]?.terminator = .continue(target: target)
    }

    private func processFallthroughStatement(_ fallthroughStmt: FallThroughStmtSyntax) {
        addStatementToCurrentBlock(Syntax(fallthroughStmt))
        // The fallthrough target is connected when the next case processes.
        cfg.blocks[currentBlockID]?.terminator = .fallthrough(newBlock())
    }

    private func processDoStatement(_ doStmt: DoStmtSyntax) {
        processCodeBlock(doStmt.body)

        for catchClause in doStmt.catchClauses {
            let catchBlock = newBlock()
            // Exception flow from the do body to each catch.
            pendingConnections.append((from: currentBlockID, to: catchBlock))

            switchToBlock(catchBlock)
            processCodeBlock(catchClause.body)
        }
    }

    // MARK: - Statement addition

    private func addStatementToCurrentBlock(_ syntax: Syntax) {
        let loc = converter.location(for: syntax.positionAfterSkippingLeadingTrivia)
        let location = SourceLocation(file: file, line: loc.line, column: loc.column, offset: 0)

        let extractor = UseDefExtractor()
        extractor.walk(syntax)

        let statement = CFGStatement(
            syntax: syntax,
            location: location,
            uses: extractor.uses,
            defs: extractor.defs
        )

        cfg.blocks[currentBlockID]?.statements.append(statement)
    }

    // MARK: - USE/DEF computation

    private func computeUseDef() {
        for id in cfg.blockOrder {
            guard var block = cfg.blocks[id] else { continue }

            var use = Set<VariableID>()
            var def = Set<VariableID>()
            var defNames = Set<String>()

            for statement in block.statements {
                // USE = variables used before being defined, by name — a
                // variable used at one scope but defined at another still
                // counts as defined-before-use.
                for usedVar in statement.uses where !defNames.contains(usedVar.name) {
                    use.insert(usedVar)
                }
                def.formUnion(statement.defs)
                defNames.formUnion(statement.defs.map(\.name))
            }

            block.use = use
            block.def = def
            cfg.blocks[id] = block
        }
    }
}

// MARK: - UseDefExtractor

/// Extracts variable uses and definitions from syntax with scope-aware
/// tracking. Closures are handled conservatively: everything referenced
/// inside a closure counts as used (captures).
private final class UseDefExtractor: SyntaxVisitor {
    var uses = Set<VariableID>()
    var defs = Set<VariableID>()

    /// Current scope nesting depth.
    let scopeDepth: Int

    init(scopeDepth: Int = 0) {
        self.scopeDepth = scopeDepth
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - Variable references (reads)

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        uses.insert(VariableID(name: node.baseName.text, scopeDepth: scopeDepth))
        return .visitChildren
    }

    // MARK: - Variable bindings (writes)

    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        extractDefsFromPattern(node.pattern)
        return .visitChildren
    }

    /// Recursively extract definitions from any pattern type.
    private func extractDefsFromPattern(_ pattern: PatternSyntax) {
        if let identifier = pattern.as(IdentifierPatternSyntax.self) {
            defs.insert(VariableID(name: identifier.identifier.text, scopeDepth: scopeDepth))
        } else if let tuple = pattern.as(TuplePatternSyntax.self) {
            for element in tuple.elements {
                extractDefsFromPattern(element.pattern)
            }
        } else if let valueBinding = pattern.as(ValueBindingPatternSyntax.self) {
            extractDefsFromPattern(valueBinding.pattern)
        } else if let expression = pattern.as(ExpressionPatternSyntax.self) {
            extractDefsFromExpression(expression.expression)
        }
        // Wildcards and type patterns bind nothing.
    }

    /// Extract definitions from expression patterns (enum case bindings).
    private func extractDefsFromExpression(_ expr: ExprSyntax) {
        if let functionCall = expr.as(FunctionCallExprSyntax.self) {
            for argument in functionCall.arguments {
                extractDefsFromExpression(argument.expression)
            }
        } else if let declRef = expr.as(DeclReferenceExprSyntax.self) {
            defs.insert(VariableID(name: declRef.baseName.text, scopeDepth: scopeDepth))
        }
    }

    // MARK: - Assignment expressions

    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        // After operator folding, `=` is AssignmentExprSyntax and compound
        // assignments (+=) are BinaryOperatorExprSyntax. Comparisons that
        // merely end in `=` (==, !=, <=, >=) are not assignments.
        let operatorText: String? =
            if node.operator.is(AssignmentExprSyntax.self) {
                "="
            } else if let op = node.operator.as(BinaryOperatorExprSyntax.self) {
                op.operator.text
            } else {
                nil
            }
        let comparisons: Set<String> = ["==", "!=", "<=", ">="]
        guard let operatorText,
            operatorText.hasSuffix("="),
            !comparisons.contains(operatorText)
        else {
            return .visitChildren
        }

        if let declRef = node.leftOperand.as(DeclReferenceExprSyntax.self) {
            let varID = VariableID(name: declRef.baseName.text, scopeDepth: scopeDepth)
            defs.insert(varID)
            // Plain assignment doesn't read the LHS; compound assignment
            // (+=) both reads and writes. Walking only the RHS keeps the
            // LHS out of the use set (a full child walk would re-add it).
            if operatorText != "=" {
                uses.insert(varID)
            }
            walk(node.rightOperand)
            return .skipChildren
        }

        // Member/subscript writes read their base; the default walk
        // collects the base reference.
        return .visitChildren
    }

    // MARK: - For loop pattern

    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        extractDefsFromPattern(node.pattern)
        return .visitChildren
    }

    // MARK: - Guard/if let bindings

    override func visit(_ node: OptionalBindingConditionSyntax) -> SyntaxVisitorContinueKind {
        extractDefsFromPattern(node.pattern)
        return .visitChildren
    }

    // MARK: - Closures (conservative)

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        // Everything a closure references is a potential capture: mark it
        // used to prevent false dead-store positives.
        let captureExtractor = ClosureCaptureExtractor(scopeDepth: scopeDepth + 1)
        captureExtractor.walk(node)
        uses.formUnion(captureExtractor.capturedVariables)
        return .skipChildren
    }
}

// MARK: - ClosureCaptureExtractor

/// Extracts variables referenced inside a closure body (potential captures).
private final class ClosureCaptureExtractor: SyntaxVisitor {
    /// Variables referenced in the closure (potential captures).
    var capturedVariables = Set<VariableID>()

    /// Variables defined inside the closure (not captures).
    var localVariables = Set<String>()

    let scopeDepth: Int

    init(scopeDepth: Int) {
        self.scopeDepth = scopeDepth
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        let name = node.baseName.text
        if !localVariables.contains(name) {
            // Parent scope depth for potential captures.
            capturedVariables.insert(VariableID(name: name, scopeDepth: scopeDepth - 1))
        }
        return .visitChildren
    }

    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        if let identifier = node.pattern.as(IdentifierPatternSyntax.self) {
            localVariables.insert(identifier.identifier.text)
        }
        return .visitChildren
    }
}
