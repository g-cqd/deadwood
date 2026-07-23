// swift-format-ignore-file
// Operator functions are used through operator syntax, which produces no
// identifier reference — they must be roots (never flagged).
struct Money: Equatable {
    var cents: Int

    static func == (lhs: Money, rhs: Money) -> Bool {
        lhs.cents == rhs.cents
    }
}

private func + (lhs: Money, rhs: Money) -> Money {
    Money(cents: lhs.cents + rhs.cents)
}

func total(_ a: Money, _ b: Money) -> Bool {
    let sum = a + b
    return sum == a
}
