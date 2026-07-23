//  Lifted from SwiftStaticAnalysis (MIT) — UnusedCodeDetector/DataFlow/ReachingDefinitions.swift.
//  Changes during the lift: `Heap` replaced by the CollectionShims
//  BinaryHeap; model types nested under the analysis; the
//  CombinedDataFlowAnalysis sugar, Set-extension helper, and debug output
//  trimmed.

// MARK: - ReachingDefinitionsAnalysis

/// Forward data flow analysis for reaching definitions: def-use chains and
/// potentially uninitialized uses per function body. Restricts the
/// `dead-store` rule to stores that are actually overwritten (through
/// `DeadBranchPass`).
struct ReachingDefinitionsAnalysis: Sendable {
    /// A variable definition at a specific location.
    struct DefinitionSite: Sendable, Hashable {
        /// The variable being defined.
        let variable: String

        /// Block containing the definition.
        let block: BlockID

        /// Index of the statement in the block.
        let statementIndex: Int

        /// Source location of the definition.
        let location: SourceLocation

        /// The value being assigned (if extractable).
        let value: String?

        /// Whether this is an initial definition (entry block).
        let isInitial: Bool

        init(
            variable: String,
            block: BlockID,
            statementIndex: Int,
            location: SourceLocation,
            value: String? = nil,
            isInitial: Bool = false
        ) {
            self.variable = variable
            self.block = block
            self.statementIndex = statementIndex
            self.location = location
            self.value = value
            self.isInitial = isInitial
        }
    }

    /// A use of a potentially uninitialized variable.
    struct UninitializedUse: Sendable {
        /// The variable being used.
        let variable: String

        /// Location of the use.
        let location: SourceLocation

        /// How many definitions may reach this use.
        let reachingDefinitionCount: Int

        /// Whether the variable is definitely uninitialized.
        let definitelyUninitialized: Bool
    }

    /// Results from reaching definitions analysis.
    struct Result: Sendable {
        /// The analyzed CFG.
        let cfg: ControlFlowGraph

        /// All definition sites found.
        let definitions: [DefinitionSite]

        /// Definitions reaching the entry of each block.
        let reachIn: [BlockID: Set<DefinitionSite>]

        /// Definitions reaching the exit of each block.
        let reachOut: [BlockID: Set<DefinitionSite>]

        /// Potentially uninitialized variable uses.
        let uninitializedUses: [UninitializedUse]

        /// Definition-use chains.
        let defUseChains: [DefinitionSite: Set<SourceLocation>]
    }

    /// Configuration for the analysis.
    struct Configuration: Sendable {
        static let `default` = Self()

        /// Maximum iterations for the fixed-point computation.
        var maxIterations: Int

        /// Whether to detect uninitialized uses.
        var detectUninitializedUses: Bool

        /// Whether to build def-use chains.
        var buildDefUseChains: Bool

        /// Variables to ignore in analysis.
        var ignoredVariables: Set<String>

        init(
            maxIterations: Int = 1000,
            detectUninitializedUses: Bool = true,
            buildDefUseChains: Bool = true,
            ignoredVariables: Set<String> = ["_"]
        ) {
            self.maxIterations = maxIterations
            self.detectUninitializedUses = detectUninitializedUses
            self.buildDefUseChains = buildDefUseChains
            self.ignoredVariables = ignoredVariables
        }
    }

    private let configuration: Configuration

    init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    /// Analyze a control flow graph for reaching definitions.
    func analyze(_ cfg: ControlFlowGraph) -> Result {
        let definitions = collectDefinitions(cfg)

        var genSets: [BlockID: Set<DefinitionSite>] = [:]
        var killSets: [BlockID: Set<DefinitionSite>] = [:]

        for id in cfg.blockOrder {
            guard let block = cfg.blocks[id] else { continue }
            let (gen, kill) = computeGenKill(block: block, definitions: definitions)
            genSets[id] = gen
            killSets[id] = kill
        }

        let (reachIn, reachOut) = computeReachingDefinitions(
            cfg: cfg,
            genSets: genSets,
            killSets: killSets
        )

        var uninitializedUses: [UninitializedUse] = []
        if configuration.detectUninitializedUses {
            uninitializedUses = findUninitializedUses(cfg: cfg, reachIn: reachIn)
        }

        var defUseChains: [DefinitionSite: Set<SourceLocation>] = [:]
        if configuration.buildDefUseChains {
            defUseChains = buildDefUseChains(cfg: cfg, reachIn: reachIn)
        }

        return Result(
            cfg: cfg,
            definitions: definitions,
            reachIn: reachIn,
            reachOut: reachOut,
            uninitializedUses: uninitializedUses,
            defUseChains: defUseChains
        )
    }

    // MARK: - Definition collection

    private func collectDefinitions(_ cfg: ControlFlowGraph) -> [DefinitionSite] {
        var definitions: [DefinitionSite] = []

        for id in cfg.blockOrder {
            guard let block = cfg.blocks[id] else { continue }

            for (index, statement) in block.statements.enumerated() {
                for variable in statement.defs {
                    if configuration.ignoredVariables.contains(variable.name) {
                        continue
                    }

                    definitions.append(
                        DefinitionSite(
                            variable: variable.name,
                            block: id,
                            statementIndex: index,
                            location: statement.location,
                            value: statement.shortDescription(maxLength: 50),
                            isInitial: id == .entry && index == 0
                        ))
                }
            }
        }

        return definitions
    }

    // MARK: - GEN/KILL sets

    private func computeGenKill(
        block: BasicBlock,
        definitions: [DefinitionSite]
    ) -> (gen: Set<DefinitionSite>, kill: Set<DefinitionSite>) {
        var gen = Set<DefinitionSite>()
        var kill = Set<DefinitionSite>()

        for (index, statement) in block.statements.enumerated() {
            for variable in statement.defs {
                if configuration.ignoredVariables.contains(variable.name) {
                    continue
                }

                // GEN: definitions created in this block.
                let newDef = definitions.first {
                    $0.block == block.id && $0.statementIndex == index && $0.variable == variable.name
                }
                if let newDef {
                    gen.insert(newDef)
                }

                // KILL: all other definitions of this variable.
                let killed = definitions.filter {
                    $0.variable == variable.name && ($0.block != block.id || $0.statementIndex != index)
                }
                kill.formUnion(killed)

                // Later same-block redefinitions kill earlier GEN entries.
                gen = gen.filter { $0.variable != variable.name || $0.statementIndex == index }
            }
        }

        return (gen, kill)
    }

    // MARK: - Worklist algorithm

    /// Iterative worklist over a `BinaryHeap<Int>` keyed on the block's
    /// reverse-postorder index: forward analysis wants shallow blocks
    /// first. O(B × maxIterations × log B).
    private func computeReachingDefinitions(
        cfg: ControlFlowGraph,
        genSets: [BlockID: Set<DefinitionSite>],
        killSets: [BlockID: Set<DefinitionSite>]
    ) -> (reachIn: [BlockID: Set<DefinitionSite>], reachOut: [BlockID: Set<DefinitionSite>]) {
        var reachIn: [BlockID: Set<DefinitionSite>] = [:]
        var reachOut: [BlockID: Set<DefinitionSite>] = [:]

        for id in cfg.blockOrder {
            reachIn[id] = []
            reachOut[id] = genSets[id] ?? []
        }

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

        var worklist = BinaryHeap<Int>()
        var inWorklist = Set<Int>()
        worklist.reserveCapacity(blockByWorkIndex.count)
        for blockID in cfg.blockOrder {
            if let index = workIndex[blockID], inWorklist.insert(index).inserted {
                worklist.insert(index)
            }
        }
        var iterations = 0

        while let nextIndex = worklist.popMin(), iterations < configuration.maxIterations {
            if Task.isCancelled { break }
            iterations += 1
            inWorklist.remove(nextIndex)

            guard nextIndex >= 0, nextIndex < blockByWorkIndex.count else { continue }
            let blockID = blockByWorkIndex[nextIndex]
            guard let block = cfg.blocks[blockID] else { continue }

            // REACH_in = ∪ REACH_out[P] over predecessors P.
            var newReachIn = Set<DefinitionSite>()
            for predID in block.predecessors {
                if let predReachOut = reachOut[predID] {
                    newReachIn.formUnion(predReachOut)
                }
            }

            // REACH_out = GEN ∪ (REACH_in − KILL).
            let gen = genSets[blockID] ?? []
            let kill = killSets[blockID] ?? []
            let newReachOut = gen.union(newReachIn.subtracting(kill))

            if newReachIn != reachIn[blockID] || newReachOut != reachOut[blockID] {
                reachIn[blockID] = newReachIn
                reachOut[blockID] = newReachOut

                for successorID in block.successors {
                    if let successorIndex = workIndex[successorID],
                        inWorklist.insert(successorIndex).inserted
                    {
                        worklist.insert(successorIndex)
                    }
                }
            }
        }

        return (reachIn, reachOut)
    }

    // MARK: - Uninitialized use detection

    private func findUninitializedUses(
        cfg: ControlFlowGraph,
        reachIn: [BlockID: Set<DefinitionSite>]
    ) -> [UninitializedUse] {
        var uninitializedUses: [UninitializedUse] = []

        for id in cfg.blockOrder {
            guard let block = cfg.blocks[id] else { continue }

            var reachingDefs = reachIn[id] ?? []

            for statement in block.statements {
                for usedVar in statement.uses {
                    if configuration.ignoredVariables.contains(usedVar.name) {
                        continue
                    }

                    let varDefs = reachingDefs.filter { $0.variable == usedVar.name }

                    if varDefs.isEmpty {
                        uninitializedUses.append(
                            UninitializedUse(
                                variable: usedVar.name,
                                location: statement.location,
                                reachingDefinitionCount: 0,
                                definitelyUninitialized: true
                            ))
                    }
                }

                for definedVar in statement.defs {
                    updateDefinition(
                        in: &reachingDefs,
                        variable: definedVar.name,
                        block: id,
                        location: statement.location
                    )
                }
            }
        }

        return uninitializedUses
    }

    // MARK: - Def-use chains

    private func buildDefUseChains(
        cfg: ControlFlowGraph,
        reachIn: [BlockID: Set<DefinitionSite>]
    ) -> [DefinitionSite: Set<SourceLocation>] {
        var chains: [DefinitionSite: Set<SourceLocation>] = [:]

        for id in cfg.blockOrder {
            guard let block = cfg.blocks[id] else { continue }

            var reachingDefs = reachIn[id] ?? []

            for statement in block.statements {
                for usedVar in statement.uses {
                    let varDefs = reachingDefs.filter { $0.variable == usedVar.name }
                    for def in varDefs {
                        chains[def, default: []].insert(statement.location)
                    }
                }

                for definedVar in statement.defs {
                    updateDefinition(
                        in: &reachingDefs,
                        variable: definedVar.name,
                        block: id,
                        location: statement.location
                    )
                }
            }
        }

        return chains
    }

    /// Kill old definitions for a variable and insert the new one.
    private func updateDefinition(
        in definitions: inout Set<DefinitionSite>,
        variable: String,
        block: BlockID,
        location: SourceLocation
    ) {
        definitions = definitions.filter { $0.variable != variable }
        definitions.insert(
            DefinitionSite(
                variable: variable,
                block: block,
                statementIndex: -1,
                location: location
            ))
    }
}
