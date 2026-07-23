//  Lifted from SwiftStaticAnalysis (MIT) — UnusedCodeDetector/DataFlow/SCCPAnalysis.swift.
//  Trimmed: the debug-description extension.

import Foundation
import SwiftSyntax

// MARK: - LatticeValue

/// The value of a variable in the SCCP lattice.
enum LatticeValue: Sendable, Hashable, CustomStringConvertible {
    /// Top: unknown value (not yet computed).
    case top

    /// Constant: known compile-time constant.
    case constant(ConstantValue)

    /// Bottom: varying/non-constant.
    case bottom

    var description: String {
        switch self {
        case .top:
            "⊤"
        case .constant(let value):
            "const(\(value))"
        case .bottom:
            "⊥"
        }
    }

    /// Meet operation: combines two lattice values.
    func meet(_ other: Self) -> Self {
        switch (self, other) {
        case (.top, let value), (let value, .top):
            value

        case (_, .bottom), (.bottom, _):
            .bottom

        case (.constant(let first), .constant(let second)):
            if first == second {
                .constant(first)
            } else {
                .bottom
            }
        }
    }
}

// MARK: - ConstantValue

/// A compile-time constant value.
enum ConstantValue: Sendable, Hashable, CustomStringConvertible {
    case int(Int)
    case double(Double)
    case bool(Bool)
    case string(String)
    case `nil`

    var description: String {
        switch self {
        case .int(let value): "\(value)"
        case .double(let value): "\(value)"
        case .bool(let value): "\(value)"
        case .string(let value): "\"\(value)\""
        case .nil: "nil"
        }
    }
}

// MARK: - CFGEdge

/// An edge in the CFG for SCCP executability tracking.
struct CFGEdge: Hashable, Sendable {
    let from: BlockID
    let to: BlockID

    init(from: BlockID, to: BlockID) {
        self.from = from
        self.to = to
    }
}

// MARK: - DeadBranch

/// A branch that is never taken.
struct DeadBranch: Sendable {
    enum BranchDirection: String, Sendable {
        case trueBranch
        case falseBranch
    }

    /// Location of the branch condition.
    let location: SourceLocation

    /// The branch condition text.
    let condition: String

    /// Whether the true or false branch is dead.
    let deadBranch: BranchDirection

    /// The constant value of the condition.
    let conditionValue: String

    init(
        location: SourceLocation,
        condition: String,
        deadBranch: BranchDirection,
        conditionValue: String
    ) {
        self.location = location
        self.condition = condition
        self.deadBranch = deadBranch
        self.conditionValue = conditionValue
    }
}

// MARK: - SCCPResult

/// Results from SCCP analysis.
struct SCCPResult: Sendable {
    /// The analyzed CFG.
    let cfg: ControlFlowGraph

    /// Lattice values for variables.
    let variableValues: [String: LatticeValue]

    /// Executable edges.
    let executableEdges: Set<CFGEdge>

    /// Unreachable blocks.
    let unreachableBlocks: Set<BlockID>

    /// Dead branches found.
    let deadBranches: [DeadBranch]

    /// Constants that can be propagated.
    let propagatableConstants:
        [(
            variable: String,
            value: ConstantValue,
            location: SourceLocation
        )]

    init(
        cfg: ControlFlowGraph,
        variableValues: [String: LatticeValue],
        executableEdges: Set<CFGEdge>,
        unreachableBlocks: Set<BlockID>,
        deadBranches: [DeadBranch],
        propagatableConstants: [(variable: String, value: ConstantValue, location: SourceLocation)]
    ) {
        self.cfg = cfg
        self.variableValues = variableValues
        self.executableEdges = executableEdges
        self.unreachableBlocks = unreachableBlocks
        self.deadBranches = deadBranches
        self.propagatableConstants = propagatableConstants
    }
}

// MARK: - SCCPAnalysis

/// Sparse conditional constant propagation.
final class SCCPAnalysis: Sendable {
    /// Configuration for the analysis.
    struct Configuration: Sendable {
        static let `default` = Self()

        /// Maximum iterations for the fixed-point computation.
        var maxIterations: Int

        /// Whether to detect dead branches.
        var detectDeadBranches: Bool

        /// Whether to track string constants.
        var trackStrings: Bool

        /// Variables to ignore in analysis.
        var ignoredVariables: Set<String>

        init(
            maxIterations: Int = 1000,
            detectDeadBranches: Bool = true,
            trackStrings: Bool = false,
            ignoredVariables: Set<String> = ["_"]
        ) {
            self.maxIterations = maxIterations
            self.detectDeadBranches = detectDeadBranches
            self.trackStrings = trackStrings
            self.ignoredVariables = ignoredVariables
        }
    }

    private let configuration: Configuration

    init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    /// Analyze a control flow graph using SCCP.
    func analyze(_ cfg: ControlFlowGraph) -> SCCPResult {
        var session = SCCPAnalysisSession(configuration: configuration, cfg: cfg)
        return session.run()
    }
}

// MARK: - SCCPAnalysisSession

private struct SCCPAnalysisSession {
    private let configuration: SCCPAnalysis.Configuration
    private let cfg: ControlFlowGraph

    /// Lattice values for variables.
    private var values: [String: LatticeValue] = [:]

    /// Executable edges.
    private var executableEdges: Set<CFGEdge> = []

    /// SSA definition worklist.
    private var ssaWorklist: [String] = []

    /// CFG edge worklist.
    private var cfgWorklist: [CFGEdge] = []

    /// Blocks that have been visited.
    private var visitedBlocks: Set<BlockID> = []

    /// Inverted use-chain: variable name → blocks referencing it. Built
    /// lazily on the first `propagateValue`.
    private var useChain: [String: Set<BlockID>] = [:]
    private var useChainBuilt = false

    init(configuration: SCCPAnalysis.Configuration, cfg: ControlFlowGraph) {
        self.configuration = configuration
        self.cfg = cfg
    }

    // MARK: - Execution

    mutating func run() -> SCCPResult {
        cfgWorklist.append(CFGEdge(from: .entry, to: cfg.entryBlock))

        var iterations = 0

        while !cfgWorklist.isEmpty || !ssaWorklist.isEmpty, iterations < configuration.maxIterations {
            // Cooperative cancellation: pathological nesting can drive the
            // iteration count high; check the flag every outer turn so a
            // cancel terminates promptly with a partial result.
            if Task.isCancelled { break }
            iterations += 1

            while let edge = cfgWorklist.popLast() {
                if executableEdges.insert(edge).inserted {
                    visitBlock(edge.to)
                }
            }

            while let variable = ssaWorklist.popLast() {
                propagateValue(variable)
            }
        }

        let unreachableBlocks = findUnreachableBlocks()
        let deadBranches = configuration.detectDeadBranches ? findDeadBranches() : []
        let constants = findPropagatableConstants()

        return SCCPResult(
            cfg: cfg,
            variableValues: values,
            executableEdges: executableEdges,
            unreachableBlocks: unreachableBlocks,
            deadBranches: deadBranches,
            propagatableConstants: constants
        )
    }

    // MARK: - Block processing

    private mutating func visitBlock(_ blockID: BlockID) {
        guard let block = cfg.blocks[blockID] else { return }

        let firstVisit = !visitedBlocks.contains(blockID)
        visitedBlocks.insert(blockID)

        for statement in block.statements {
            evaluateStatement(statement)
        }

        if let terminator = block.terminator {
            processTerminator(terminator, in: blockID, firstVisit: firstVisit)
        }
    }

    private mutating func evaluateStatement(_ statement: CFGStatement) {
        // Per-variable RHS lookup so `let x = 42` populates the lattice —
        // evaluating the whole VariableDeclSyntax never matches any
        // expression case and would degrade every variable to bottom.
        let initializers = extractInitializers(from: statement.syntax)

        for variable in statement.defs {
            if configuration.ignoredVariables.contains(variable.name) {
                continue
            }
            let value: LatticeValue
            if let rhs = initializers[variable.name] {
                value = evaluateExpression(rhs)
            } else {
                value = evaluateExpression(statement.syntax)
            }
            updateValue(variable: variable.name, value: value)
        }
    }

    /// `name -> initializer expression` mappings for variable declarations
    /// and pattern bindings; empty for other syntax kinds.
    private func extractInitializers(from syntax: Syntax) -> [String: Syntax] {
        var out: [String: Syntax] = [:]
        if let varDecl = syntax.as(VariableDeclSyntax.self) {
            for binding in varDecl.bindings {
                guard let value = binding.initializer?.value else { continue }
                if let id = binding.pattern.as(IdentifierPatternSyntax.self) {
                    out[id.identifier.text] = Syntax(value)
                }
            }
        } else if let binding = syntax.as(PatternBindingSyntax.self),
            let value = binding.initializer?.value,
            let id = binding.pattern.as(IdentifierPatternSyntax.self)
        {
            out[id.identifier.text] = Syntax(value)
        }
        return out
    }

    private func evaluateExpression(_ syntax: Syntax) -> LatticeValue {
        if let intLit = syntax.as(IntegerLiteralExprSyntax.self),
            let value = Int(intLit.literal.text)
        {
            return .constant(.int(value))
        }

        if let boolLit = syntax.as(BooleanLiteralExprSyntax.self) {
            return .constant(.bool(boolLit.literal.text == "true"))
        }

        if configuration.trackStrings, let strLit = syntax.as(StringLiteralExprSyntax.self) {
            return .constant(.string(strLit.segments.description))
        }

        if syntax.is(NilLiteralExprSyntax.self) {
            return .constant(.nil)
        }

        if let declRef = syntax.as(DeclReferenceExprSyntax.self) {
            return values[declRef.baseName.text] ?? .top
        }

        if let infixExpr = syntax.as(InfixOperatorExprSyntax.self) {
            return evaluateBinaryOp(infixExpr)
        }

        if let prefixExpr = syntax.as(PrefixOperatorExprSyntax.self) {
            return evaluatePrefixOp(prefixExpr)
        }

        return .bottom
    }

    private func evaluateBinaryOp(_ expr: InfixOperatorExprSyntax) -> LatticeValue {
        guard let op = expr.operator.as(BinaryOperatorExprSyntax.self) else {
            return .bottom
        }

        let opText = op.operator.text
        let leftValue = evaluateExpression(Syntax(expr.leftOperand))
        let rightValue = evaluateExpression(Syntax(expr.rightOperand))

        if case .top = leftValue { return .top }
        if case .top = rightValue { return .top }
        if case .bottom = leftValue { return .bottom }
        if case .bottom = rightValue { return .bottom }

        guard case .constant(let left) = leftValue,
            case .constant(let right) = rightValue
        else {
            return .bottom
        }

        if case .int(let lhs) = left, case .int(let rhs) = right {
            switch opText {
            case "+": return .constant(.int(lhs + rhs))
            case "-": return .constant(.int(lhs - rhs))
            case "*": return .constant(.int(lhs * rhs))
            case "/": return rhs != 0 ? .constant(.int(lhs / rhs)) : .bottom
            case "%": return rhs != 0 ? .constant(.int(lhs % rhs)) : .bottom
            case "==": return .constant(.bool(lhs == rhs))
            case "!=": return .constant(.bool(lhs != rhs))
            case "<": return .constant(.bool(lhs < rhs))
            case "<=": return .constant(.bool(lhs <= rhs))
            case ">": return .constant(.bool(lhs > rhs))
            case ">=": return .constant(.bool(lhs >= rhs))
            default: break
            }
        }

        if case .bool(let lhs) = left, case .bool(let rhs) = right {
            switch opText {
            case "&&": return .constant(.bool(lhs && rhs))
            case "||": return .constant(.bool(lhs || rhs))
            case "==": return .constant(.bool(lhs == rhs))
            case "!=": return .constant(.bool(lhs != rhs))
            default: break
            }
        }

        return .bottom
    }

    private func evaluatePrefixOp(_ expr: PrefixOperatorExprSyntax) -> LatticeValue {
        let opText = expr.operator.text
        let operandValue = evaluateExpression(Syntax(expr.expression))

        if case .top = operandValue { return .top }
        if case .bottom = operandValue { return .bottom }

        guard case .constant(let operand) = operandValue else {
            return .bottom
        }

        switch opText {
        case "!":
            if case .bool(let value) = operand {
                return .constant(.bool(!value))
            }

        case "-":
            if case .int(let value) = operand {
                return .constant(.int(-value))
            }
            if case .double(let value) = operand {
                return .constant(.double(-value))
            }

        default:
            break
        }

        return .bottom
    }

    // MARK: - Terminator processing

    private mutating func processTerminator(_ terminator: Terminator, in blockID: BlockID, firstVisit: Bool) {
        switch terminator {
        case .branch(let target):
            cfgWorklist.append(CFGEdge(from: blockID, to: target))

        case .conditionalBranch(let condition, let trueTarget, let falseTarget):
            let condValue = evaluateCondition(condition)

            switch condValue {
            case .constant(.bool(true)):
                cfgWorklist.append(CFGEdge(from: blockID, to: trueTarget))

            case .constant(.bool(false)):
                cfgWorklist.append(CFGEdge(from: blockID, to: falseTarget))

            case .top:
                if firstVisit {
                    cfgWorklist.append(CFGEdge(from: blockID, to: trueTarget))
                    cfgWorklist.append(CFGEdge(from: blockID, to: falseTarget))
                }

            case .bottom, .constant:
                cfgWorklist.append(CFGEdge(from: blockID, to: trueTarget))
                cfgWorklist.append(CFGEdge(from: blockID, to: falseTarget))
            }

        case .switch(_, let cases, let defaultTarget):
            for (_, target) in cases {
                cfgWorklist.append(CFGEdge(from: blockID, to: target))
            }
            if let defaultTarget {
                cfgWorklist.append(CFGEdge(from: blockID, to: defaultTarget))
            }

        case .return, .throw, .unreachable:
            cfgWorklist.append(CFGEdge(from: blockID, to: .exit))

        case .fallthrough(let target):
            cfgWorklist.append(CFGEdge(from: blockID, to: target))

        case .break(let target):
            if let target {
                cfgWorklist.append(CFGEdge(from: blockID, to: target))
            }

        case .continue(let target):
            if let target {
                cfgWorklist.append(CFGEdge(from: blockID, to: target))
            }
        }
    }

    private func evaluateCondition(_ condition: String) -> LatticeValue {
        let trimmed = condition.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "true" {
            return .constant(.bool(true))
        }
        if trimmed == "false" {
            return .constant(.bool(false))
        }

        if let value = values[trimmed] {
            return value
        }

        return .bottom
    }

    // MARK: - Value propagation

    private mutating func updateValue(variable: String, value: LatticeValue) {
        let oldValue = values[variable] ?? .top
        let newValue = oldValue.meet(value)

        if newValue != oldValue {
            values[variable] = newValue
            ssaWorklist.append(variable)
        }
    }

    private mutating func propagateValue(_ variable: String) {
        buildUseChainIfNeeded()
        guard let users = useChain[variable] else { return }
        for blockID in users where visitedBlocks.contains(blockID) {
            visitBlock(blockID)
        }
    }

    /// Build a `name → blocks-that-use-it` index from the CFG: statement
    /// uses plus conditional/switch terminator condition strings (which
    /// `evaluateCondition` looks up by name).
    private mutating func buildUseChainIfNeeded() {
        guard !useChainBuilt else { return }
        useChainBuilt = true
        for (blockID, block) in cfg.blocks {
            for statement in block.statements {
                for use in statement.uses {
                    useChain[use.name, default: []].insert(blockID)
                }
            }
            guard let terminator = block.terminator else { continue }
            switch terminator {
            case .conditionalBranch(let condition, _, _), .switch(let condition, _, _):
                let trimmed = condition.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    useChain[trimmed, default: []].insert(blockID)
                }

            default:
                break
            }
        }
    }

    // MARK: - Result computation

    private func findUnreachableBlocks() -> Set<BlockID> {
        var unreachable = Set<BlockID>()

        for id in cfg.blockOrder {
            if id == .entry { continue }

            let hasExecutableIncoming = executableEdges.contains { $0.to == id }
            if !hasExecutableIncoming {
                unreachable.insert(id)
            }
        }

        return unreachable
    }

    private func findDeadBranches() -> [DeadBranch] {
        var deadBranches: [DeadBranch] = []

        for id in cfg.blockOrder {
            guard let block = cfg.blocks[id] else { continue }

            if case .conditionalBranch(let condition, let trueTarget, let falseTarget) = block.terminator {
                let condValue = evaluateCondition(condition)

                let location: SourceLocation =
                    if let lastStmt = block.statements.last {
                        lastStmt.location
                    } else {
                        SourceLocation(file: cfg.file, line: 0, column: 0, offset: 0)
                    }

                switch condValue {
                case .constant(.bool(true)):
                    if !executableEdges.contains(CFGEdge(from: id, to: falseTarget)) {
                        deadBranches.append(
                            DeadBranch(
                                location: location,
                                condition: condition,
                                deadBranch: .falseBranch,
                                conditionValue: "true"
                            ))
                    }

                case .constant(.bool(false)):
                    if !executableEdges.contains(CFGEdge(from: id, to: trueTarget)) {
                        deadBranches.append(
                            DeadBranch(
                                location: location,
                                condition: condition,
                                deadBranch: .trueBranch,
                                conditionValue: "false"
                            ))
                    }

                default:
                    break
                }
            }
        }

        return deadBranches
    }

    private func findPropagatableConstants() -> [(
        variable: String,
        value: ConstantValue,
        location: SourceLocation
    )] {
        var constants: [(String, ConstantValue, SourceLocation)] = []

        for id in cfg.blockOrder {
            guard let block = cfg.blocks[id] else { continue }

            for statement in block.statements {
                for variable in statement.defs {
                    if let latticeValue = values[variable.name],
                        case .constant(let constValue) = latticeValue
                    {
                        constants.append((variable.name, constValue, statement.location))
                    }
                }
            }
        }

        return constants
    }
}
