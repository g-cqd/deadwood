import DeadwoodCore
import Testing

/// A variable is constant only if the propagation saw every write to it.
@Suite struct DeadBranchSoundnessTests {
    private func deadBranches(_ source: String) -> [Finding] {
        Analyzer().analyze(source: source, path: "Sample.swift").findings.filter { $0.rule == .deadBranch }
    }

    @Test func `a variable written inside a closure is not constant`() {
        let findings = deadBranches(
            """
            func createFile(atPath path: String) -> Bool {
                var didWrite = false
                path.withCString { _ in
                    didWrite = true
                }
                if didWrite {
                    return true
                }
                return false
            }
            """)

        #expect(findings.isEmpty)
    }

    @Test func `a variable written in a catch inside a loop is not constant`() {
        let findings = deadBranches(
            """
            func pasteAll(_ items: [Int]) async -> Int {
                var isAccessDenied = false
                var failures = 0
                for item in items {
                    do {
                        try await load(item)
                    } catch {
                        isAccessDenied = true
                        failures += 1
                    }
                }
                if isAccessDenied {
                    return -1
                }
                return failures
            }
            """)

        #expect(findings.isEmpty)
    }

    @Test func `a variable passed inout is not constant`() {
        let findings = deadBranches(
            """
            func refresh() -> Int {
                var isStale = false
                markStale(&isStale)
                if isStale {
                    return 1
                }
                return 0
            }
            """)

        #expect(findings.isEmpty)
    }

    @Test func `a constant still folds after a do-catch, at high confidence`() {
        let findings = deadBranches(
            """
            func gated() -> Int {
                let isEnabled = false
                do {
                    try prepare()
                } catch {
                    print(error)
                }
                if isEnabled {
                    return 1
                }
                return 0
            }
            """)

        #expect(findings.count == 1)
        #expect(findings.first?.line == 8)
        #expect(findings.first?.note?.hasPrefix("confidence high") == true)
    }
}
