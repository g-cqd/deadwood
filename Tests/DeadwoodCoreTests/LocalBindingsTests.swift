import Testing

@testable import DeadwoodCore

/// The names a body binds itself are not uses of a member of the same name.
@Suite struct LocalBindingsTests {
    private func names(_ source: String) -> Set<String> {
        LocalBindings.names(in: source)
    }

    @Test func `let, var, if let, guard let and case let bind`() {
        #expect(names("let a = 1; var b = 2").isSuperset(of: ["a", "b"]))
        #expect(
            names("guard let device = try? make(), let other = device.next else { return }").isSuperset(of: [
                "device", "other",
            ])
        )
        #expect(names("if let value { use(value) }").contains("value"))
        #expect(names("switch x { case let y: break }").contains("y"))
    }

    @Test func `tuple and enum patterns bind each name`() {
        #expect(names("let (first, second) = pair").isSuperset(of: ["first", "second"]))
        #expect(names("case let .found(item, index): break").isSuperset(of: ["item", "index"]))
        #expect(names("case .found(label: let name, _): break").contains("name"))
    }

    @Test func `closure parameters and loop variables bind`() {
        #expect(names("items.map { element in element.id }").contains("element"))
        #expect(names("zip(a, b).map { [weak self] left, right in left + right }").isSuperset(of: ["left", "right"]))
        #expect(names("run { (value: Int, other: String) -> Bool in true }").isSuperset(of: ["value", "other"]))
        #expect(names("for item in items {}").contains("item"))
        #expect(names("for (key, value) in table {}").isSuperset(of: ["key", "value"]))
        #expect(names("for case let match? in results {}").contains("match"))
    }

    @Test func `the names the language supplies bind`() {
        #expect(names("do { try run() } catch { log(error) }").contains("error"))
        #expect(names("didSet { update(oldValue) }").contains("oldValue"))
        #expect(names("set { store = newValue }").contains("newValue"))
    }

    @Test func `a plain use binds nothing`() {
        #expect(names("view.title = header; render(header.count)").isEmpty)
        #expect(!names("let a = items.first; use(items)").contains("items"))
    }
}
