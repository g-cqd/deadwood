// swift-format-ignore-file
// Ported from SwiftStaticAnalysis UnusedCodeScenarios/ProtocolWitnesses.
// Protocol witnesses (corpus-internal and stdlib), operator conformances,
// CodingKeys, and description properties must never be flagged; the only
// findings are the private members that witness nothing.
import Foundation

protocol Displayable {
    func display()
}

protocol Identifiable {
    var id: String { get }
}

protocol Processable {
    associatedtype Output
    func process() -> Output
}

struct User: Displayable, Identifiable {
    let name: String

    /// Satisfies Identifiable — not unused.
    var id: String {
        "user-\(name)"
    }

    /// Satisfies Displayable — not unused.
    func display() {
        print("User: \(name)")
    }
}

struct Product: Displayable, Identifiable {
    let title: String
    let price: Double

    var id: String {
        "product-\(title)"
    }

    func display() {
        print("Product: \(title) - $\(price)")
    }
}

struct Order: Processable {
    let items: [String]

    /// Witness with associated type — not unused.
    func process() -> [String] {
        items.map { "Processed: \($0)" }
    }
}

func showAll(_ items: [any Displayable]) {
    for item in items {
        item.display()
    }
}

func getAllIds(_ items: [some Identifiable]) -> [String] {
    items.map(\.id)
}

struct Point: Equatable, Hashable {
    let x: Int
    let y: Int

    /// Operator conformance — used through `==` syntax.
    static func == (lhs: Point, rhs: Point) -> Bool {
        lhs.x == rhs.x && lhs.y == rhs.y
    }

    /// Hashable witness — invoked by the hasher.
    func hash(into hasher: inout Hasher) {
        hasher.combine(x)
        hasher.combine(y)
    }
}

struct Config: Codable {
    /// CodingKeys is consumed by Codable synthesis.
    enum CodingKeys: String, CodingKey {
        case name
        case value = "val"
    }

    let name: String
    let value: Int
}

struct DebugInfo: CustomStringConvertible {
    let message: String

    /// CustomStringConvertible witness.
    var description: String {
        "Debug: \(message)"
    }
}

struct UnusedStruct {
    // oracle:begin
    private var unusedProperty: Int {  // #dw:expect unused-property
        42
    }

    private func unusedMethod() {  // #dw:expect unused-function
        print("unused")
    }
    // oracle:end
}

class NonConformingClass {
    // oracle:begin
    private func helper() {  // #dw:expect unused-function
        print("helper")
    }
    // oracle:end
}

protocol Defaultable {
    func requiredMethod()
    func optionalMethod()
}

extension Defaultable {
    /// Default implementation — kept alive by the requirement.
    func optionalMethod() {
        print("default implementation")
    }
}

struct DefaultUser: Defaultable {
    func requiredMethod() {
        print("required")
    }
}

func runConformanceTests() {
    let users: [any Displayable] = [
        User(name: "Alice"),
        Product(title: "Widget", price: 9.99),
    ]
    showAll(users)

    let items = [User(name: "Bob"), User(name: "Charlie")]
    let ids = getAllIds(items)
    print(ids)

    let order = Order(items: ["A", "B", "C"])
    print(order.process())
}
