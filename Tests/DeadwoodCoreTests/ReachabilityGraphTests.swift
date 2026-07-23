//  Ported from SwiftStaticAnalysis UnusedCodeDetectorTests/ReachabilityGraphTests
//  (adapted: single-edge mutators and path finding were trimmed, so edges go
//  in as batches; node identity is the dense declaration index).

import Testing

@testable import DeadwoodCore

@Suite("Reachability Graph")
struct ReachabilityGraphTests {
    @Test("Empty graph has no unreachable nodes")
    func emptyGraph() async {
        let graph = ReachabilityGraph()
        await graph.prepare(declarationCount: 0)
        let unreachable = await graph.computeUnreachable()
        #expect(unreachable.isEmpty)
        #expect(await graph.nodeCount == 0)
    }

    @Test("Root nodes are reachable")
    func rootNodesReachable() async {
        let graph = ReachabilityGraph()
        await graph.prepare(declarationCount: 1)
        await graph.markRoot(0)

        let unreachable = await graph.computeUnreachable()
        #expect(unreachable.isEmpty)
    }

    @Test("Edges make targets reachable")
    func edgeReachability() async {
        let graph = ReachabilityGraph()
        await graph.prepare(declarationCount: 2)
        await graph.markRoot(0)
        await graph.addEdges([DependencyEdge(from: 0, to: 1, kind: .call)])

        let unreachable = await graph.computeUnreachable()
        #expect(unreachable.isEmpty)
    }

    @Test("Unreachable nodes are detected")
    func unreachableNodes() async {
        let graph = ReachabilityGraph()
        await graph.prepare(declarationCount: 2)
        await graph.markRoot(0)

        let unreachable = await graph.computeUnreachable()
        #expect(unreachable == [1])
    }

    @Test("Transitive chains are fully reachable")
    func transitiveReachability() async {
        let graph = ReachabilityGraph()
        await graph.prepare(declarationCount: 4)
        await graph.markRoot(0)
        await graph.addEdges([
            DependencyEdge(from: 0, to: 1, kind: .call),
            DependencyEdge(from: 1, to: 2, kind: .call),
        ])

        let unreachable = await graph.computeUnreachable()
        #expect(unreachable == [3])
    }

    @Test("Duplicate edges are deduplicated, not double-counted")
    func duplicateEdges() async {
        let graph = ReachabilityGraph()
        await graph.prepare(declarationCount: 2)
        await graph.markRoot(0)
        await graph.addEdges([
            DependencyEdge(from: 0, to: 1, kind: .call),
            DependencyEdge(from: 0, to: 1, kind: .call),
            DependencyEdge(from: 0, to: 1, kind: .propertyAccess),
        ])

        #expect(await graph.computeUnreachable().isEmpty)
    }

    @Test("Out-of-range edges and roots are ignored")
    func outOfRangeInputs() async {
        let graph = ReachabilityGraph()
        await graph.prepare(declarationCount: 2)
        await graph.markRoot(9)
        await graph.markRoot(-1)
        await graph.addEdges([
            DependencyEdge(from: 0, to: 9, kind: .call),
            DependencyEdge(from: -3, to: 1, kind: .call),
        ])

        // No roots inside range: everything is unreachable, nothing traps.
        #expect(await graph.computeUnreachable() == [0, 1])
    }

    @Test("Mutation invalidates the reachability cache")
    func cacheInvalidation() async {
        let graph = ReachabilityGraph()
        await graph.prepare(declarationCount: 2)
        await graph.markRoot(0)

        #expect(await graph.computeUnreachable().count == 1)

        await graph.addEdges([DependencyEdge(from: 0, to: 1, kind: .call)])

        #expect(await graph.computeUnreachable().isEmpty)
    }

    @Test("detectRoots sizes the graph and marks entry points")
    func detectRootsSizesGraph() async {
        let main = makeDecl(name: "main", kind: .function, line: 1)
        let orphan = makeDecl(name: "orphan", kind: .function, access: .private, line: 5)
        let graph = ReachabilityGraph()
        await graph.detectRoots(declarations: [main, orphan], context: makeContext([main, orphan]))

        #expect(await graph.nodeCount == 2)
        // Index 0 (`main`) is a root; index 1 (`orphan`) is unreachable.
        #expect(await graph.computeUnreachable() == [1])
    }

    @Test("Parallel and sequential unreachable sets agree")
    func parallelSequentialAgreement() async {
        let graph = ReachabilityGraph()
        await graph.prepare(declarationCount: 50)
        await graph.markRoot(0)
        var edges: [DependencyEdge] = []
        for index in 1..<40 {
            edges.append(DependencyEdge(from: Int32(index - 1), to: Int32(index), kind: .call))
        }
        await graph.addEdges(edges)

        let sequential = Set(await graph.computeUnreachable())
        let parallel = Set(
            await graph.computeUnreachableParallel(
                configuration: ParallelBFS.Configuration(minParallelSize: 1)
            ))

        #expect(sequential == parallel)
        #expect(sequential.count == 10)
    }
}
