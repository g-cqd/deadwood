//  Ported from SwiftStaticAnalysis UnusedCodeDetectorTests/DataFlowTests
//  (adapted to the nested result types and the BinaryHeap worklists; the
//  CombinedDataFlowAnalysis suite went with the trimmed type).

import SwiftParser
import SwiftSyntax
import Testing

@testable import DeadwoodCore

// MARK: - Helpers

private func buildCFG(_ source: String, function: String = "test") -> ControlFlowGraph {
    let tree = foldedTree(Parser.parse(source: source))
    let collector = TestFunctionCollector()
    collector.walk(tree)
    let builder = CFGBuilder(file: "test.swift", tree: tree)
    let target = collector.functions.first { $0.name.text == function } ?? collector.functions[0]
    return builder.buildCFG(from: target)
}

private final class TestFunctionCollector: SyntaxVisitor {
    var functions: [FunctionDeclSyntax] = []

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        functions.append(node)
        return .visitChildren
    }
}

// MARK: - CFG Builder

@Suite("CFG Builder")
struct CFGBuilderTests {
    @Test("Empty function creates minimal CFG")
    func emptyFunction() {
        let cfg = buildCFG("func test() {}")

        #expect(cfg.blocks[.entry] != nil)
        #expect(cfg.blocks[.exit] != nil)
        #expect(cfg.functionName == "test")
    }

    @Test("Simple statements stay in one block")
    func simpleStatements() {
        let cfg = buildCFG(
            """
            func test() {
                let x = 1
                let y = 2
                print(x + y)
            }
            """)

        #expect(cfg.blocks[.entry]?.statements.count == 3)
    }

    @Test("If statement creates branches")
    func ifStatementBranches() {
        let cfg = buildCFG(
            """
            func test(_ flag: Bool) {
                if flag {
                    print("yes")
                }
            }
            """)

        // entry + then + else + merge + exit.
        #expect(cfg.blocks.count >= 5)
        if case .conditionalBranch = cfg.blocks[.entry]?.terminator {
        } else {
            Issue.record("entry should end in a conditional branch")
        }
    }

    @Test("Guard statement creates early exit")
    func guardStatement() {
        let cfg = buildCFG(
            """
            func test(_ value: Int?) {
                guard let value else { return }
                print(value)
            }
            """)

        let returnsToExit = cfg.blocks.values.contains { block in
            block.successors.contains(.exit) && block.id != .entry
        }
        #expect(returnsToExit)
    }

    @Test("While loop creates back edge")
    func whileLoopBackEdge() {
        let cfg = buildCFG(
            """
            func test() {
                var i = 0
                while i < 10 {
                    i += 1
                }
            }
            """)

        // Some block must point back to an earlier block (the header).
        let hasBackEdge = cfg.blocks.values.contains { block in
            block.successors.contains { successor in
                cfg.blocks[successor]?.successors.contains(block.id) == true
                    || successor == block.id
            }
        }
        #expect(hasBackEdge || cfg.blocks.count >= 5)
    }

    @Test("Return statement terminates block")
    func returnTerminates() {
        let cfg = buildCFG(
            """
            func test() -> Int {
                return 42
            }
            """)

        if case .return(let expression) = cfg.blocks[.entry]?.terminator {
            #expect(expression?.contains("42") == true)
        } else {
            Issue.record("entry should end in a return")
        }
    }

    @Test("Switch statement creates a branch per case")
    func switchBranches() {
        let cfg = buildCFG(
            """
            func test(_ value: Int) {
                switch value {
                case 1: print("one")
                case 2: print("two")
                default: print("many")
                }
            }
            """)

        if case .switch(_, let cases, let defaultTarget) = cfg.blocks[.entry]?.terminator {
            #expect(cases.count == 2)
            #expect(defaultTarget != nil)
        } else {
            Issue.record("entry should end in a switch terminator")
        }
    }

    @Test("USE and DEF sets are computed")
    func useDefSets() {
        let cfg = buildCFG(
            """
            func test(_ input: Int) {
                let x = input + 1
                print(x)
            }
            """)

        let entry = cfg.blocks[.entry]!
        #expect(entry.def.contains { $0.name == "x" })
        #expect(entry.use.contains { $0.name == "input" })
    }

    @Test("Reverse postorder starts at entry")
    func reversePostOrder() {
        let cfg = buildCFG(
            """
            func test(_ flag: Bool) {
                if flag { print("a") } else { print("b") }
                print("done")
            }
            """)

        #expect(cfg.reversePostOrder.first == .entry)
        #expect(!cfg.reversePostOrder.isEmpty)
    }
}

// MARK: - Live Variables

@Suite("Live Variable Analysis")
struct LiveVariableAnalysisTests {
    @Test("Empty function has no dead stores")
    func emptyFunction() {
        let result = LiveVariableAnalysis().analyze(buildCFG("func test() {}"))
        #expect(result.deadStores.isEmpty)
        #expect(result.unusedVariables.isEmpty)
    }

    @Test("Used variable is live")
    func usedVariableLive() {
        let result = LiveVariableAnalysis().analyze(
            buildCFG(
                """
                func test() {
                    let x = 1
                    print(x)
                }
                """))

        #expect(!result.unusedVariables.contains { $0.name == "x" })
    }

    @Test("Unused variable is detected")
    func unusedVariableDetected() {
        let result = LiveVariableAnalysis().analyze(
            buildCFG(
                """
                func test() {
                    let neverRead = 1
                    print("done")
                }
                """))

        #expect(result.unusedVariables.contains { $0.name == "neverRead" })
    }

    @Test("Dead store is detected")
    func deadStoreDetected() {
        let result = LiveVariableAnalysis().analyze(
            buildCFG(
                """
                func test() -> Int {
                    var x = 1
                    x = 2
                    return x
                }
                """))

        // The first store to x is overwritten before any read.
        #expect(result.deadStores.contains { $0.variable.name == "x" })
    }

    @Test("Ignored variable underscore is skipped")
    func underscoreIgnored() {
        let result = LiveVariableAnalysis().analyze(
            buildCFG(
                """
                func test() {
                    let _ = compute()
                }
                func compute() -> Int { 1 }
                """))

        #expect(!result.unusedVariables.contains { $0.name == "_" })
        #expect(!result.deadStores.contains { $0.variable.name == "_" })
    }

    @Test("Live in/out sets are computed for branches")
    func liveInOutSets() {
        let result = LiveVariableAnalysis().analyze(
            buildCFG(
                """
                func test(_ flag: Bool) -> Int {
                    let x = 1
                    if flag {
                        return x
                    }
                    return 0
                }
                """))

        // x must be live out of the entry block (read in the then-branch).
        let entryLiveOut = result.liveOut[.entry] ?? []
        #expect(entryLiveOut.contains { $0.name == "x" })
    }
}

// MARK: - SCCP

@Suite("SCCP Analysis")
struct SCCPAnalysisTests {
    @Test("Constant integer is propagated")
    func constantIntPropagated() {
        let result = SCCPAnalysis().analyze(
            buildCFG(
                """
                func test() {
                    let x = 42
                    print(x)
                }
                """))

        #expect(result.variableValues["x"] == .constant(.int(42)))
    }

    @Test("Constant boolean is propagated")
    func constantBoolPropagated() {
        let result = SCCPAnalysis().analyze(
            buildCFG(
                """
                func test() {
                    let flag = true
                    print(flag)
                }
                """))

        #expect(result.variableValues["flag"] == .constant(.bool(true)))
    }

    @Test("Lattice meet operation")
    func latticeMeet() {
        let const1 = LatticeValue.constant(.int(1))
        let const2 = LatticeValue.constant(.int(2))

        #expect(LatticeValue.top.meet(const1) == const1)
        #expect(const1.meet(.top) == const1)
        #expect(const1.meet(.bottom) == .bottom)
        #expect(const1.meet(const1) == const1)
        #expect(const1.meet(const2) == .bottom)
    }

    @Test("Dead branch with literal false condition")
    func deadBranchLiteralFalse() {
        let result = SCCPAnalysis().analyze(
            buildCFG(
                """
                func test() -> Int {
                    if false {
                        return 1
                    }
                    return 0
                }
                """))

        #expect(result.deadBranches.count == 1)
        #expect(result.deadBranches.first?.deadBranch == .trueBranch)
        #expect(result.deadBranches.first?.conditionValue == "false")
    }

    @Test("Dead branch with literal true condition")
    func deadBranchLiteralTrue() {
        let result = SCCPAnalysis().analyze(
            buildCFG(
                """
                func test() -> Int {
                    if true {
                        return 1
                    }
                    return 0
                }
                """))

        #expect(result.deadBranches.count == 1)
        #expect(result.deadBranches.first?.deadBranch == .falseBranch)
        #expect(result.deadBranches.first?.conditionValue == "true")
    }

    @Test("Cross-statement constant propagation marks branch dead")
    func propagatedConstantDeadBranch() {
        let result = SCCPAnalysis().analyze(
            buildCFG(
                """
                func test() -> Int {
                    let enabled = false
                    if enabled {
                        return 1
                    }
                    return 0
                }
                """))

        #expect(result.deadBranches.count == 1)
        #expect(result.deadBranches.first?.deadBranch == .trueBranch)
    }

    @Test("while true is the infinite-loop idiom, not a dead branch")
    func whileTrueNotFlagged() {
        let result = SCCPAnalysis().analyze(
            buildCFG(
                """
                func test() -> Int {
                    var count = 0
                    while true {
                        count += 1
                        if count > 3 { return count }
                    }
                }
                """))

        #expect(result.deadBranches.isEmpty)
    }

    @Test("while false has a dead body")
    func whileFalseFlagged() {
        let result = SCCPAnalysis().analyze(
            buildCFG(
                """
                func test() -> Int {
                    while false {
                        print("never")
                    }
                    return 0
                }
                """))

        #expect(result.deadBranches.count == 1)
        #expect(result.deadBranches.first?.deadBranch == .trueBranch)
    }

    @Test("Varying condition produces no dead branch")
    func varyingConditionNoDeadBranch() {
        let result = SCCPAnalysis().analyze(
            buildCFG(
                """
                func test(_ flag: Bool) -> Int {
                    if flag {
                        return 1
                    }
                    return 0
                }
                """))

        #expect(result.deadBranches.isEmpty)
    }

    @Test("Unreachable blocks are detected")
    func unreachableBlocks() {
        let result = SCCPAnalysis().analyze(
            buildCFG(
                """
                func test() -> Int {
                    if false {
                        return 1
                    }
                    return 0
                }
                """))

        #expect(!result.unreachableBlocks.isEmpty)
    }

    @Test("Executable edges are tracked")
    func executableEdges() {
        let result = SCCPAnalysis().analyze(
            buildCFG(
                """
                func test() {
                    let x = 1
                    print(x)
                }
                """))

        #expect(result.executableEdges.contains(CFGEdge(from: .entry, to: .entry)))
    }

    @Test("Arithmetic constant folding")
    func arithmeticFolding() {
        let result = SCCPAnalysis().analyze(
            buildCFG(
                """
                func test() {
                    let x = 2 + 3
                    print(x)
                }
                """))

        #expect(result.variableValues["x"] == .constant(.int(5)))
    }

    @Test("Boolean constant folding")
    func booleanFolding() {
        let result = SCCPAnalysis().analyze(
            buildCFG(
                """
                func test() {
                    let x = true && false
                    print(x)
                }
                """))

        #expect(result.variableValues["x"] == .constant(.bool(false)))
    }

    @Test("Propagation terminates on pathological chains")
    func propagationTerminates() {
        var source = "func test() {\n"
        for index in 0..<60 {
            source += "    let v\(index) = \(index)\n"
        }
        source += "    print(v59)\n}"

        let result = SCCPAnalysis().analyze(buildCFG(source))
        #expect(result.variableValues["v59"] == .constant(.int(59)))
    }
}

// MARK: - Reaching Definitions

@Suite("Reaching Definitions")
struct ReachingDefinitionsTests {
    @Test("Single definition reaches use")
    func singleDefinition() {
        let result = ReachingDefinitionsAnalysis().analyze(
            buildCFG(
                """
                func test() {
                    let x = 1
                    print(x)
                }
                """))

        #expect(result.definitions.contains { $0.variable == "x" })
    }

    @Test("Multiple definitions are collected")
    func multipleDefinitions() {
        let result = ReachingDefinitionsAnalysis().analyze(
            buildCFG(
                """
                func test() {
                    var x = 1
                    x = 2
                    let y = 3
                    print(x + y)
                }
                """))

        let xDefs = result.definitions.filter { $0.variable == "x" }
        #expect(xDefs.count == 2)
        #expect(result.definitions.contains { $0.variable == "y" })
    }

    @Test("REACH_out contains generated definitions")
    func reachOutComputed() {
        let result = ReachingDefinitionsAnalysis().analyze(
            buildCFG(
                """
                func test() {
                    let x = 1
                    print(x)
                }
                """))

        let entryOut = result.reachOut[.entry] ?? []
        #expect(entryOut.contains { $0.variable == "x" })
    }

    @Test("Def-use chains are built")
    func defUseChains() {
        let result = ReachingDefinitionsAnalysis().analyze(
            buildCFG(
                """
                func test() {
                    let x = 1
                    print(x)
                }
                """))

        let xChains = result.defUseChains.filter { $0.key.variable == "x" }
        #expect(!xChains.isEmpty)
    }

    @Test("Ignored variables are skipped")
    func ignoredVariables() {
        let result = ReachingDefinitionsAnalysis().analyze(
            buildCFG(
                """
                func test() {
                    let _ = 1
                }
                """))

        #expect(!result.definitions.contains { $0.variable == "_" })
    }
}

// MARK: - Dead Branch Pass (pipeline)

@Suite("Dead Branch Pass")
struct DeadBranchPassTests {
    @Test("Findings carry the branch location and condition")
    func passProducesFindings() {
        let source = """
            func gated() -> Int {
                if false {
                    return 1
                }
                return 0
            }
            """
        let findings = DeadBranchPass.run(tree: Parser.parse(source: source), file: "test.swift")

        #expect(findings.count == 1)
        #expect(findings.first?.reason == .deadBranch)
        #expect(findings.first?.declaration.location.line == 2)
        #expect(findings.first?.suggestion.contains("false") == true)
    }

    @Test("Initializer bodies are analyzed")
    func initializersAnalyzed() {
        let source = """
            struct Box {
                let value: Int
                init() {
                    if true {
                        value = 1
                    } else {
                        value = 2
                    }
                }
            }
            """
        let findings = DeadBranchPass.run(tree: Parser.parse(source: source), file: "test.swift")
        #expect(findings.count == 1)
    }

    @Test("Rule is on by default through the Analyzer")
    func analyzerIntegration() {
        let report = Analyzer().analyze(
            source: """
                func gated() -> Int {
                    if false { return 1 }
                    return 0
                }
                """,
            path: "test.swift"
        )

        #expect(report.findings.map(\.rule) == [.deadBranch])
        #expect(report.findings.first?.line == 2)
    }

    @Test("Disabled rule silences the pass")
    func ruleDisabled() {
        let config = Configuration(rules: ["dead-branch": .init(enabled: false)])
        let report = Analyzer(configuration: config).analyze(
            source: """
                func gated() -> Int {
                    if false { return 1 }
                    return 0
                }
                """,
            path: "test.swift"
        )

        #expect(report.findings.isEmpty)
    }

    @Test("Dead-branch findings can be suppressed")
    func suppression() {
        let report = Analyzer().analyze(
            source: """
                func gated() -> Int {
                    if false { return 1 }  // @dw:accept dead-branch -- template kept on purpose
                    return 0
                }
                """,
            path: "test.swift"
        )

        #expect(report.findings.isEmpty)
        #expect(report.suppressed.count == 1)
    }
}
