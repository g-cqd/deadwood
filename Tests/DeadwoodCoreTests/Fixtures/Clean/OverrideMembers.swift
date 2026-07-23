//  Overridden members dispatch dynamically through the parent: a call on a
//  Base reference can land in Sub.describe, so overrides are rooted.

private class Base {
    func describe() -> String { "base" }
}

private final class Sub: Base {
    override func describe() -> String { "sub" }
}

func render(_ value: Base) -> String {
    value.describe()
}

func makeSub() -> Base {
    Sub()
}

@main
struct OverrideMain {
    static func main() {
        _ = render(makeSub())
    }
}
