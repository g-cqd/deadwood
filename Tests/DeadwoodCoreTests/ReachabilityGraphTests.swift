//  Ported from SwiftStaticAnalysis UnusedCodeDetectorTests/ReachabilityGraphTests
//  (adapted: single-edge mutators and path finding were trimmed, so edges go
//  in as batches).

import Testing

@testable import DeadwoodCore

@Suite("Reachability Graph")
struct ReachabilityGraphTests {
    @Test("Empty graph has no unreachable nodes")
    func emptyGraph() async {
        let graph = ReachabilityGraph()
        let unreachable = await graph.computeUnreachable()
        #expect(unreachable.isEmpty)
        #expect(await graph.nodeCount == 0)
    }

    @Test("Root nodes are reachable")
    func rootNodesReachable() async {
        let graph = ReachabilityGraph()
        let decl = makeDecl(name: "main", kind: .function)

        await graph.addNode(decl, isRoot: true, rootReason: .mainFunction)

        let unreachable = await graph.computeUnreachable()
        #expect(unreachable.isEmpty)
    }

    @Test("Edges make targets reachable")
    func edgeReachability() async {
        let graph = ReachabilityGraph()
        let mainDecl = makeDecl(name: "main", kind: .function, line: 1)
        let helperDecl = makeDecl(name: "helper", kind: .function, line: 10)

        await graph.addNode(mainDecl, isRoot: true, rootReason: .mainFunction)
        await graph.addNode(helperDecl)
        await graph.addEdges([
            DependencyEdge(
                from: DeclarationNode(declaration: mainDecl).id,
                to: DeclarationNode(declaration: helperDecl).id,
                kind: .call
            )
        ])

        let unreachable = await graph.computeUnreachable()
        #expect(unreachable.isEmpty)
    }

    @Test("Unreachable nodes are detected")
    func unreachableNodes() async {
        let graph = ReachabilityGraph()
        let mainDecl = makeDecl(name: "main", kind: .function, line: 1)
        let orphanDecl = makeDecl(name: "orphan", kind: .function, line: 20)

        await graph.addNode(mainDecl, isRoot: true, rootReason: .mainFunction)
        await graph.addNode(orphanDecl)

        let unreachable = await graph.computeUnreachable()
        #expect(unreachable.count == 1)
        #expect(unreachable.first?.declaration.name == "orphan")
    }

    @Test("Transitive chains are fully reachable")
    func transitiveReachability() async {
        let graph = ReachabilityGraph()
        let declA = makeDecl(name: "a", kind: .function, line: 1)
        let declB = makeDecl(name: "b", kind: .function, line: 2)
        let declC = makeDecl(name: "c", kind: .function, line: 3)
        let declD = makeDecl(name: "d", kind: .function, line: 4)

        await graph.addNode(declA, isRoot: true, rootReason: .mainFunction)
        for decl in [declB, declC, declD] {
            await graph.addNode(decl)
        }
        await graph.addEdges([
            DependencyEdge(
                from: DeclarationNode(declaration: declA).id,
                to: DeclarationNode(declaration: declB).id,
                kind: .call
            ),
            DependencyEdge(
                from: DeclarationNode(declaration: declB).id,
                to: DeclarationNode(declaration: declC).id,
                kind: .call
            ),
        ])

        let unreachable = await graph.computeUnreachable()
        #expect(unreachable.map(\.declaration.name) == ["d"])
    }

    @Test("Mutation invalidates the reachability cache")
    func cacheInvalidation() async {
        let graph = ReachabilityGraph()
        let root = makeDecl(name: "root", kind: .function, line: 1)
        let late = makeDecl(name: "late", kind: .function, line: 9)

        await graph.addNode(root, isRoot: true, rootReason: .mainFunction)
        await graph.addNode(late)

        #expect(await graph.computeUnreachable().count == 1)

        await graph.addEdges([
            DependencyEdge(
                from: DeclarationNode(declaration: root).id,
                to: DeclarationNode(declaration: late).id,
                kind: .call
            )
        ])

        #expect(await graph.computeUnreachable().isEmpty)
    }

    @Test("Parallel and sequential unreachable sets agree")
    func parallelSequentialAgreement() async {
        let graph = ReachabilityGraph()
        var edges: [DependencyEdge] = []
        var previous: Declaration?
        for index in 0..<50 {
            let decl = makeDecl(name: "f\(index)", kind: .function, line: index + 1)
            await graph.addNode(decl, isRoot: index == 0, rootReason: index == 0 ? .mainFunction : nil)
            if let previous, index < 40 {
                edges.append(
                    DependencyEdge(
                        from: DeclarationNode(declaration: previous).id,
                        to: DeclarationNode(declaration: decl).id,
                        kind: .call
                    ))
            }
            previous = decl
        }
        await graph.addEdges(edges)

        let sequential = Set(await graph.computeUnreachable().map(\.id))
        let parallel = Set(
            await graph.computeUnreachableParallel(
                configuration: ParallelBFS.Configuration(minParallelSize: 1)
            ).map(\.id))

        #expect(sequential == parallel)
        #expect(sequential.count == 10)
    }
}
