import Testing

@testable import DeadwoodCore

/// A type conforms to what its protocols inherit: `struct S: Entity` with `protocol Entity: Hashable` is `Hashable`, and its
/// `hash(into:)` is called by the standard library. A superclass of the corpus is no unknown protocol, so it exempts nothing.
@Suite("Witnesses through the corpus's own protocols")
struct ProtocolInheritanceWitnessTests {
    private static func entry(_ uses: String) -> String {
        """
        @main
        struct App {
            static func main() {
                \(uses)
            }
        }

        """
    }

    private func messages(
        _ source: String,
        uses: String = "print(Set([User(name: \"a\")]).count, Circle(), Derived().extra)"
    ) async throws -> [String] {
        let report = try await CorpusFixture(["Sources/App/App.swift": Self.entry(uses) + source]).analyze()
        return report.findings.map(\.message)
    }

    @Test func `a witness of a protocol the corpus's protocol inherits is not reported`() async throws {
        let messages = try await messages(
            """
            protocol Entity: Hashable { var name: String { get } }

            struct User: Entity {
                let name: String
                func hash(into hasher: inout Hasher) { hasher.combine(name) }
                static func == (lhs: User, rhs: User) -> Bool { lhs.name == rhs.name }
            }

            protocol Shape: CustomStringConvertible {}
            struct Circle: Shape {
                var description: String { "circle" }
            }

            class Derived { var extra: Int { 1 } }
            """
        )
        #expect(!messages.contains { $0.contains("'hash(into:)'") || $0.contains("'description'") }, "\(messages)")
    }

    @Test func `a member nothing uses is still reported in a type of such a protocol`() async throws {
        let messages = try await messages(
            """
            protocol Shape: CustomStringConvertible {}
            struct Circle: Shape {
                var description: String { "circle" }
                var radiusLabel: String { "r" }
            }
            struct User: Hashable { let name: String }
            class Derived { var extra: Int { 1 } }
            """
        )
        #expect(messages.contains { $0.contains("'radiusLabel'") }, "\(messages)")
        #expect(!messages.contains { $0.contains("'description'") }, "\(messages)")
    }

    @Test func `a superclass of the corpus exempts none of its subclass's members`() async throws {
        let messages = try await messages(
            """
            class Base: CustomStringConvertible {
                var description: String { "base" }
            }
            class Derived: Base {
                var extra: Int { 1 }
                var neverUsed: Int { 2 }
            }
            struct User: Hashable { let name: String }
            struct Circle: CustomStringConvertible { var description: String { "c" } }
            """
        )
        #expect(messages.contains { $0.contains("'neverUsed'") }, "\(messages)")
    }

    @Test func `the customization points of Sequence and SetAlgebra are witnesses`() async throws {
        let messages = try await messages(
            """
            struct Bag: Sequence {
                func makeIterator() -> IndexingIterator<[Int]> { [1].makeIterator() }
                var underestimatedCount: Int { 1 }
                func unusedHelper() {}
            }
            struct Flags: OptionSet {
                let rawValue: Int
                func union(_ other: Flags) -> Flags { Flags(rawValue: rawValue | other.rawValue) }
                func unusedFlagHelper() {}
            }
            """,
            uses: "print(Array(Bag()), Flags(rawValue: 1).union(Flags(rawValue: 2)))"
        )
        #expect(!messages.contains { $0.contains("'underestimatedCount'") || $0.contains("'union") }, "\(messages)")
        #expect(messages.contains { $0.contains("'unusedHelper") }, "\(messages)")
        #expect(messages.contains { $0.contains("'unusedFlagHelper") }, "\(messages)")
    }
}
