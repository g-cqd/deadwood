//  New in deadwood: locks the three precision fixes made during the lift.
//  1. #selector/#keyPath arguments produce references.
//  2. Operator function declarations are roots.
//  3. Shorthand `.caseName` construction and patterns count as references.

import Testing

@testable import DeadwoodCore

@Suite("Precision Fixes")
struct PrecisionTests {
    // MARK: - Fix 1: #selector / #keyPath references

    @Test("#selector arguments produce references")
    func selectorArgumentsProduceReferences() {
        let result = makeFacts(
            """
            final class Sink {
                func wire() {
                    let action = #selector(handleTick(_:))
                    _ = action
                }
                @objc private func handleTick(_ timer: Any) {}
            }
            """)

        #expect(result.references.uniqueIdentifiers.contains("handleTick"))
    }

    @Test("#keyPath arguments produce references")
    func keyPathArgumentsProduceReferences() {
        let result = makeFacts(
            """
            final class Sink {
                @objc var progress: Double = 0
                func observe() {
                    let key = #keyPath(Sink.progress)
                    _ = key
                }
            }
            """)

        #expect(result.references.uniqueIdentifiers.contains("progress"))
    }

    @Test("A method referenced only via #selector is not unused")
    func selectorOnlyReferenceIsUse() {
        // treatObjcAsRoot is off so only the reference can save the method.
        var config = UnusedCodeConfiguration(mode: .simple, treatVisibleOutsideFileAsRoot: true)
        config.treatObjcAsRoot = false

        let result = makeFacts(
            """
            final class Sink {
                func wire() {
                    let action = #selector(handleTick(_:))
                    _ = action
                }
                private func handleTick(_ timer: Any) {}
            }
            """)
        let context = CorpusContext(result: result)
        let findings = UnusedCodeDetector(configuration: config)
            .detectFromResult(result, context: context)

        #expect(findings.isEmpty)
    }

    @Test("Swift key path literals produce references")
    func keyPathLiteralProducesReferences() {
        let result = makeFacts(
            """
            struct User { var name: String }
            func names(_ users: [User]) -> [String] {
                users.map(\\.name)
            }
            """)

        #expect(result.references.uniqueIdentifiers.contains("name"))
    }

    // MARK: - Fix 2: operator functions

    @Test("A private operator function used via operator syntax is not flagged")
    func operatorFunctionNotFlagged() {
        let result = makeFacts(
            """
            struct Money { var cents: Int }
            private func + (lhs: Money, rhs: Money) -> Money {
                Money(cents: lhs.cents + rhs.cents)
            }
            func total(_ a: Money, _ b: Money) -> Money { a + b }
            """)
        let context = CorpusContext(result: result)
        let findings = UnusedCodeDetector(
            configuration: UnusedCodeConfiguration(
                mode: .simple, treatVisibleOutsideFileAsRoot: true)
        )
        .detectFromResult(result, context: context)

        #expect(findings.isEmpty)
    }

    // MARK: - Fix 3: shorthand enum case references

    @Test("Shorthand .caseName construction counts as a reference")
    func shorthandConstructionCountsAsReference() {
        let result = makeFacts(
            """
            private enum Mode { case fast, careful }
            func pick() -> Mode { .fast }
            """)

        #expect(result.references.uniqueIdentifiers.contains("fast"))
    }

    @Test("Shorthand patterns in switch cases count as references")
    func shorthandPatternCountsAsReference() {
        let result = makeFacts(
            """
            private enum Mode { case fast, careful }
            func describe(_ mode: Mode) -> Int {
                switch mode {
                case .fast: 1
                case .careful: 2
                }
            }
            """)

        #expect(result.references.uniqueIdentifiers.contains("fast"))
        #expect(result.references.uniqueIdentifiers.contains("careful"))
    }

    @Test("A case referenced only via shorthand is not flagged; a dead case is")
    func shorthandEndToEnd() {
        let result = makeFacts(
            """
            private enum Route {
                case home
                case debugMenu
            }
            func start() -> Route { .home }
            """)
        let context = CorpusContext(result: result)
        let findings = UnusedCodeDetector(
            configuration: UnusedCodeConfiguration(
                mode: .simple, treatVisibleOutsideFileAsRoot: true)
        )
        .detectFromResult(result, context: context)

        #expect(findings.map(\.declaration.name) == ["debugMenu"])
    }
}
