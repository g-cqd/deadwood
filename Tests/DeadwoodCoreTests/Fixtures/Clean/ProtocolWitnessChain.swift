// swift-format-ignore-file
// Corpus-internal protocol: existential dispatch keeps every witness alive.
private protocol Greeter {
    func greet() -> String
}

private struct English: Greeter {
    func greet() -> String { "hello" }
}

private struct French: Greeter {
    func greet() -> String { "bonjour" }
}

func greetings() -> [String] {
    let greeters: [any Greeter] = [English(), French()]
    return greeters.map { $0.greet() }
}
