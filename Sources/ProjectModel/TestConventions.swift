/// How the test frameworks find their entry points. Neither calls a test
/// by name from source, so every tool needs the same rules to know what the
/// frameworks instantiate.
public enum TestConventions {
    /// Swift Testing marks a test function with `@Test`.
    public static let testAttribute = "Test"

    /// Swift Testing marks a suite with `@Suite`. A type holding `@Test`
    /// functions is a suite even without it.
    public static let suiteAttribute = "Suite"

    /// XCTest runs every `test…` method of an `XCTestCase` subclass.
    public static let xcTestCaseClass = "XCTestCase"

    /// The name prefix of an XCTest test method.
    public static let xcTestMethodPrefix = "test"
}
