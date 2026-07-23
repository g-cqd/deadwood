//  Lifted from SwiftStaticAnalysis (MIT) — UnusedCodeDetector/DataFlow/LiveVariableAnalysis.swift.
//  Changes during the lift: `Heap` (swift-collections) replaced by the
//  CollectionShims BinaryHeap; result/model types nested under the analysis;
//  file-level conveniences and debug output trimmed.

// MARK: - LiveVariableAnalysis

/// Backward data flow analysis for live variables: dead stores and
/// never-used definitions per function body.
// @dw:accept unused-type -- lifted data-flow pass, exercised by DataFlowTests; feeds a future dead-store rule
struct LiveVariableAnalysis: Sendable {
    /// An assignment to a variable that is never read.
    struct DeadStore: Sendable {
        /// The variable being assigned (with scope context).
        let variable: VariableID

        /// Location of the dead store.
        let location: SourceLocation

        /// The expression being assigned (if simple).
        let assignedValue: String?

        /// Suggested fix.
        let suggestion: String

        init(
            variable: VariableID,
            location: SourceLocation,
            assignedValue: String? = nil,
            suggestion: String = "Consider removing this assignment"
        ) {
            self.variable = variable
            self.location = location
            self.assignedValue = assignedValue
            self.suggestion = suggestion
        }
    }

    /// Results from live variable analysis.
    struct Result: Sendable {
        /// The analyzed CFG.
        let cfg: ControlFlowGraph

        /// Dead stores found.
        let deadStores: [DeadStore]

        /// Variables that are defined but never used.
        let unusedVariables: Set<VariableID>

        /// Live-in sets for each block.
        let liveIn: [BlockID: Set<VariableID>]

        /// Live-out sets for each block.
        let liveOut: [BlockID: Set<VariableID>]
    }

    /// Configuration for the analysis.
    struct Configuration: Sendable {
        static let `default` = Self()

        /// Maximum iterations for the fixed-point computation.
        var maxIterations: Int

        /// Whether to detect dead stores.
        var detectDeadStores: Bool

        /// Variables to ignore in analysis.
        var ignoredVariables: Set<String>

        init(
            maxIterations: Int = 1000,
            detectDeadStores: Bool = true,
            ignoredVariables: Set<String> = ["_"]
        ) {
            self.maxIterations = maxIterations
            self.detectDeadStores = detectDeadStores
            self.ignoredVariables = ignoredVariables
        }
    }

    private let configuration: Configuration

    init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    /// Analyze a control flow graph for live variables.
    func analyze(_ cfg: ControlFlowGraph) -> Result {
        var workCFG = cfg

        let (liveIn, liveOut) = computeLiveVariables(&workCFG)

        var deadStores: [DeadStore] = []
        if configuration.detectDeadStores {
            deadStores = findDeadStores(cfg: workCFG, liveOut: liveOut)
        }

        let unusedVars = findUnusedVariables(cfg: workCFG)

        return Result(
            cfg: workCFG,
            deadStores: deadStores,
            unusedVariables: unusedVars,
            liveIn: liveIn,
            liveOut: liveOut
        )
    }

    // MARK: - Worklist algorithm

    /// Iterative worklist over a `BinaryHeap<Int>` keyed on *negated*
    /// reverse-postorder index (= postorder), with an `inWorklist` set for
    /// dedup: `popMin` returns the deepest block, the correct frontier for
    /// liveness's backward sweep. O(B log B × maxIterations).
    private func computeLiveVariables(
        _ cfg: inout ControlFlowGraph
    ) -> (liveIn: [BlockID: Set<VariableID>], liveOut: [BlockID: Set<VariableID>]) {
        var liveIn: [BlockID: Set<VariableID>] = [:]
        var liveOut: [BlockID: Set<VariableID>] = [:]

        for id in cfg.blockOrder {
            liveIn[id] = []
            liveOut[id] = []
        }

        // Every block gets a unique workIndex: reachable blocks take their
        // RPO index; unreachable blocks follow in blockOrder. The inverse
        // array lets popMin recover the block.
        var workIndex: [BlockID: Int] = [:]
        workIndex.reserveCapacity(cfg.blockOrder.count)
        var blockByWorkIndex: [BlockID] = []
        blockByWorkIndex.reserveCapacity(cfg.blockOrder.count)
        for (index, blockID) in cfg.reversePostOrder.enumerated() {
            workIndex[blockID] = index
            blockByWorkIndex.append(blockID)
        }
        for blockID in cfg.blockOrder where workIndex[blockID] == nil {
            workIndex[blockID] = blockByWorkIndex.count
            blockByWorkIndex.append(blockID)
        }
        let lastWorkIndex = max(0, blockByWorkIndex.count - 1)

        func key(for blockID: BlockID) -> Int {
            lastWorkIndex - (workIndex[blockID] ?? lastWorkIndex)
        }

        var worklist = BinaryHeap<Int>()
        var inWorklist = Set<Int>()
        worklist.reserveCapacity(blockByWorkIndex.count)
        for blockID in cfg.blockOrder {
            let workKey = key(for: blockID)
            if inWorklist.insert(workKey).inserted {
                worklist.insert(workKey)
            }
        }

        var iterations = 0
        while let workKey = worklist.popMin(), iterations < configuration.maxIterations {
            if Task.isCancelled { break }
            iterations += 1
            inWorklist.remove(workKey)

            let resolvedIndex = lastWorkIndex - workKey
            guard resolvedIndex >= 0, resolvedIndex < blockByWorkIndex.count else { continue }
            let blockID = blockByWorkIndex[resolvedIndex]
            guard let block = cfg.blocks[blockID] else { continue }

            // LIVE_out = ∪ LIVE_in[S] over successors S.
            var newLiveOut = Set<VariableID>()
            for succID in block.successors {
                if let succLiveIn = liveIn[succID] {
                    newLiveOut.formUnion(succLiveIn)
                }
            }

            // LIVE_in = USE ∪ (LIVE_out − DEF), subtracting by name since
            // the same variable can carry different scope-tagged IDs.
            let defNames = Set(block.def.map(\.name))
            var newLiveIn = block.use
            newLiveIn.formUnion(newLiveOut.filter { !defNames.contains($0.name) })

            newLiveIn = newLiveIn.filter { !configuration.ignoredVariables.contains($0.name) }
            newLiveOut = newLiveOut.filter { !configuration.ignoredVariables.contains($0.name) }

            if newLiveIn != liveIn[blockID] || newLiveOut != liveOut[blockID] {
                liveIn[blockID] = newLiveIn
                liveOut[blockID] = newLiveOut

                cfg.blocks[blockID]?.liveIn = newLiveIn
                cfg.blocks[blockID]?.liveOut = newLiveOut

                for predecessorID in block.predecessors {
                    let predecessorKey = key(for: predecessorID)
                    if inWorklist.insert(predecessorKey).inserted {
                        worklist.insert(predecessorKey)
                    }
                }
            }
        }

        return (liveIn, liveOut)
    }

    // MARK: - Dead store detection

    /// Assignments whose value is not live after the assignment point.
    private func findDeadStores(
        cfg: ControlFlowGraph,
        liveOut: [BlockID: Set<VariableID>]
    ) -> [DeadStore] {
        var deadStores: [DeadStore] = []

        for id in cfg.blockOrder {
            guard let block = cfg.blocks[id] else { continue }

            var liveAtPoint = liveOut[id] ?? []
            var liveNamesAtPoint = Set(liveAtPoint.map(\.name))

            for statement in block.statements.reversed() {
                for definedVar in statement.defs {
                    if configuration.ignoredVariables.contains(definedVar.name) {
                        continue
                    }

                    if !liveNamesAtPoint.contains(definedVar.name) {
                        // `x = x + 1` uses and defines in one statement.
                        let usedInSameStatement = statement.uses.contains { $0.name == definedVar.name }

                        if !usedInSameStatement {
                            deadStores.append(
                                DeadStore(
                                    variable: definedVar,
                                    location: statement.location,
                                    assignedValue: statement.shortDescription(maxLength: 100),
                                    suggestion:
                                        "Variable '\(definedVar.name)' is assigned but never read"
                                ))
                        }
                    }
                }

                // LIVE_before = USE ∪ (LIVE_after − DEF).
                let defNames = Set(statement.defs.map(\.name))
                liveAtPoint = liveAtPoint.filter { !defNames.contains($0.name) }
                liveAtPoint.formUnion(statement.uses)
                liveNamesAtPoint = Set(liveAtPoint.map(\.name))
            }
        }

        return deadStores
    }

    // MARK: - Unused variable detection

    /// Variables defined but never used anywhere in the function.
    /// Uses statement-level use sets: `block.use` only holds
    /// used-before-defined names, which would misclassify `let x = 1;
    /// print(x)` as unused (upstream gap).
    private func findUnusedVariables(cfg: ControlFlowGraph) -> Set<VariableID> {
        var allDefined = Set<VariableID>()
        var allUsedNames = Set<String>()

        for id in cfg.blockOrder {
            guard let block = cfg.blocks[id] else { continue }
            allDefined.formUnion(block.def)
            for statement in block.statements {
                allUsedNames.formUnion(statement.uses.map(\.name))
            }
        }

        allDefined = allDefined.filter { !configuration.ignoredVariables.contains($0.name) }

        return allDefined.filter { !allUsedNames.contains($0.name) }
    }
}
