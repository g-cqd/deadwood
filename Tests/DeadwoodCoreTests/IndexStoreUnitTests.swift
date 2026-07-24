//  Index-store unit tests that need no real index: the lifted value types and
//  the declaration→USR mapping that is the crux of why the index resolves
//  same-named symbols the syntax graph conflates. Ported/adapted from
//  SwiftStaticAnalysis's IndexStoreTests. Gated: the types are macOS-only.

#if canImport(IndexStoreDB)
    import Foundation
    import Testing

    @testable import DeadwoodCore

    @Suite struct IndexStoreValueTypeTests {
        @Test func symbolNodeEqualityAndHashingByUSR() {
            let a1 = IndexSymbolNode(usr: "s:test:A", name: "A", kind: .class)
            let a2 = IndexSymbolNode(usr: "s:test:A", name: "Renamed", kind: .struct)
            let b = IndexSymbolNode(usr: "s:test:B", name: "B", kind: .class)
            #expect(a1 == a2)  // identity is the USR, not the name/kind
            #expect(a1 != b)
            #expect(Set([a1, a2, b]).count == 2)
        }

        @Test func symbolKindMapsToDeadwoodDeclarationKind() {
            #expect(IndexedSymbolKind.method.toDeclarationKind() == .method)
            #expect(IndexedSymbolKind.function.toDeclarationKind() == .function)
            #expect(IndexedSymbolKind.property.toDeclarationKind() == .variable)
            #expect(IndexedSymbolKind.module.toDeclarationKind() == .import)
            #expect(IndexedSymbolKind.protocol.toDeclarationKind() == .protocol)
        }

        @Test func rolesReflectDefinitionAndUsage() {
            let def: IndexedSymbolRoles = [.definition]
            let call: IndexedSymbolRoles = [.call]
            #expect(def.isDefinitionLike)
            #expect(!def.indicatesUsage)
            #expect(call.indicatesUsage)
            #expect(!call.isDefinitionLike)
        }

        @Test func dependencyEdgeCarriesEndpointsAndKind() {
            let edge = IndexDependencyEdge(fromUSR: "s:from", toUSR: "s:to", kind: .call)
            #expect(edge.fromUSR == "s:from")
            #expect(edge.toUSR == "s:to")
            #expect(edge.kind == .call)
        }

        @Test func indexStoreStatusUsabilityAndPath() {
            #expect(IndexStoreStatus.available(path: "/p").isUsable)
            #expect(IndexStoreStatus.stale(path: "/p", staleFiles: ["a"]).isUsable)
            #expect(!IndexStoreStatus.notFound.isUsable)
            #expect(!IndexStoreStatus.failed(error: "x").isUsable)
            #expect(IndexStoreStatus.available(path: "/p").path == "/p")
            #expect(IndexStoreStatus.notFound.path == nil)
        }

        @Test func fallbackReasonDescriptionsAreActionable() {
            #expect(FallbackReason.noIndexStore.description.contains("falling back to syntax"))
            #expect(FallbackReason.noIndexStore.description.contains("swift build"))
            #expect(FallbackReason.buildFailed(error: "boom").description.contains("boom"))
            #expect(FallbackReason.dylibNotFound.description.contains("libIndexStore"))
        }

        @Test func fallbackConfigurationDefaults() {
            let config = FallbackConfiguration.default
            #expect(!config.autoBuild)
            #expect(config.checkFreshness)
            #expect(config.allowsIndexDatabaseCreation)
        }

        @Test func pathFinderReturnsNilForProjectWithoutBuild() {
            let dir = FileManager.default.temporaryDirectory
                .appending(path: "dw-idx-empty-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            #expect(IndexStorePathFinder.findIndexStorePath(in: dir.path) == nil)
        }
    }

    // MARK: - Declaration → USR mapping (the delta mechanism)

    @Suite struct IndexDeclarationMappingTests {
        /// Two methods named `shared` in different types at different lines are
        /// the exact case the name-level syntax graph conflates. The bridge's
        /// (file, name, nearest-line) mapping must resolve each declaration to
        /// its OWN USR — the precondition for the index flagging one dead while
        /// the syntax graph keeps both alive.
        @Test func nearestLineDisambiguatesSameNamedSymbols() {
            let file = "/private/tmp/dw-map/Shapes.swift"
            let nodes = [
                IndexSymbolNode(
                    usr: "s:Alpha:shared", name: "shared", kind: .method,
                    definitionFile: file, definitionLine: 2),
                IndexSymbolNode(
                    usr: "s:Beta:shared", name: "shared", kind: .method,
                    definitionFile: file, definitionLine: 6),
            ]
            let alphaShared = makeDecl(name: "shared", kind: .method, line: 2, file: file)
            let betaShared = makeDecl(name: "shared", kind: .method, line: 6, file: file)

            let map = IndexReachabilityBridge.mapDeclarationsToUSRs(
                declarations: [alphaShared, betaShared], definitionNodes: nodes)

            #expect(map[0] == "s:Alpha:shared")
            #expect(map[1] == "s:Beta:shared")
        }

        @Test func attributeLineOffsetStillMatchesWithinTolerance() {
            let file = "/private/tmp/dw-map/Attr.swift"
            let nodes = [
                IndexSymbolNode(
                    usr: "s:obj:thing", name: "thing", kind: .method,
                    definitionFile: file, definitionLine: 11)
            ]
            // Declaration line 9 (an `@objc`/modifier prefix pushed the symbol
            // token to 11); within the 5-line tolerance.
            let decl = makeDecl(name: "thing", kind: .method, line: 9, file: file)
            let map = IndexReachabilityBridge.mapDeclarationsToUSRs(
                declarations: [decl], definitionNodes: nodes)
            #expect(map[0] == "s:obj:thing")
        }

        @Test func unmatchedDeclarationIsLeftUnmapped() {
            let file = "/private/tmp/dw-map/None.swift"
            let nodes = [
                IndexSymbolNode(
                    usr: "s:x:present", name: "present", kind: .function,
                    definitionFile: file, definitionLine: 3)
            ]
            let missing = makeDecl(name: "absent", kind: .function, line: 3, file: file)
            let map = IndexReachabilityBridge.mapDeclarationsToUSRs(
                declarations: [missing], definitionNodes: nodes)
            #expect(map[0] == nil)
        }
    }
#endif
