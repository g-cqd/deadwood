//  An extension's access level is the default for its members, not a cap on them: a public member of an
//  internal extension, and an unannotated member of a public extension, are public API.

import Testing

@testable import DeadwoodCore

@Suite("Effective access of extension members")
struct EffectiveAccessTests {
    private func access(of name: String, in source: String) throws -> AccessLevel {
        let result = makeFacts(source)
        let context = CorpusContext(result: result)
        let declaration = try #require(result.declarations.declarations.first { $0.name == name })
        return context.effectiveAccess(of: declaration)
    }

    @Test("An unannotated member of a public extension of an outside type is public")
    func unannotatedMemberOfPublicExtension() throws {
        let source = "public extension Int { func member() {} }"
        #expect(try access(of: "member", in: source) == .public)
    }

    @Test("An explicitly public member of an internal extension of an outside type is public")
    func explicitMemberOfInternalExtension() throws {
        let source = "extension Int { public func member() {} }"
        #expect(try access(of: "member", in: source) == .public)
    }

    @Test("An unannotated member of an internal extension stays internal")
    func unannotatedMemberOfInternalExtension() throws {
        let source = "extension Int { func member() {} }"
        #expect(try access(of: "member", in: source) == .internal)
    }

    @Test("A private member of a public extension stays private")
    func privateMemberOfPublicExtension() throws {
        let source = "public extension Int { private func member() {} }"
        #expect(try access(of: "member", in: source) == .private)
    }

    @Test("The extended type's own access still caps its extension's members")
    func extendedTypeCapsMembers() throws {
        let source = """
            struct Hidden {}
            public extension Hidden { func member() {} }
            """
        #expect(try access(of: "member", in: source) == .internal)
    }

    @Test("A public extension of a public type in the corpus keeps its members public")
    func publicExtensionOfPublicType() throws {
        let source = """
            public struct Shown {}
            public extension Shown { func member() {} }
            """
        #expect(try access(of: "member", in: source) == .public)
    }

    @Test("A member of a type nested in a public extension is capped by that type")
    func nestedTypeCaps() throws {
        let source = """
            public extension Int {
                struct Box { func member() {} }
            }
            """
        #expect(try access(of: "member", in: source) == .internal)
    }
}
