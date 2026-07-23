// swift-format-ignore-file
// Property-wrapper synthesis: `wrappedValue`/`projectedValue` are read by the
// compiler at every use of the wrapper, and a wrapped property initialized
// through the memberwise init is referenced only by its argument label.
@propertyWrapper struct Clamped {
    var wrappedValue: Int
    var projectedValue: Bool { wrappedValue > 0 }
}

struct RetryPolicy {
    @Clamped var retries: Int = 3
}

@main struct WrapperMain {
    static func main() {
        _ = RetryPolicy(retries: Clamped(wrappedValue: 1))
    }
}
