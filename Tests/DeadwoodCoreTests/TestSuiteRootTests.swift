import DeadwoodCore
import Testing

/// The test frameworks instantiate suites; nothing references them by name.
@Suite struct TestSuiteRootTests {
    @Test func `types holding @Test functions are suites, at any depth`() async throws {
        let report = try await CorpusFixture([
            "Tests/SampleTests.swift": """
            import Testing

            enum SampleGroup {
                struct NestedRoleSuite {
                    @Test(arguments: [1, 2])
                    func `a role is granted`(level: Int) {
                        #expect(level > 0)
                    }
                }

                struct ReaderRole {
                    @Test func `a reader reads`() {
                        #expect(true)
                    }
                }
            }
            """
        ]).analyze()

        #expect(!report.flags("SampleGroup"))
        #expect(!report.flags("NestedRoleSuite"))
        #expect(!report.flags("ReaderRole"))
    }

    @Test func `an XCTestCase subclass is a suite whatever its name`() async throws {
        let report = try await CorpusFixture([
            "Tests/SampleChecks.swift": """
            import XCTest

            class SampleCase: XCTestCase {}

            final class SampleChecks: SampleCase {
                func testSomething() {
                    XCTAssertTrue(true)
                }
            }
            """
        ]).analyze()

        #expect(!report.flags("SampleChecks"))
        #expect(!report.flags("SampleCase"))
    }

    @Test func `a type in a test file without tests is still reported`() async throws {
        let report = try await CorpusFixture([
            "Tests/SampleTests.swift": """
            import Testing

            struct Checks {
                @Test func `it works`() {
                    #expect(true)
                }
            }

            struct UnusedFixture {
                let value = 1
            }
            """
        ]).analyze()

        #expect(!report.flags("Checks"))
        #expect(report.flags("UnusedFixture"))
    }
}
