import SourceCorpus

//  New in deadwood (production mode): decides which declarations belong to
//  test code, so the second reachability pass can drop their roots and the
//  `referenced-only-by-tests` findings never point INTO test code.

// MARK: - TestScopeClassifier

/// Classifies corpus declarations as test-scoped: test methods (`test…`
/// prefix or `@Test`), declarations inside `XCTestCase` subclasses or
/// `@Suite` types, and everything in test files: those matching the tests glob when one is set, else those the project
/// or the content says are test code (ADR-0024).
struct TestScopeClassifier: Sendable {
    /// Custom glob for test files, read as analyzerkit's `PathFilter` reads an `exclude` entry (ADR-0008); nil takes
    /// the test region of each file.
    let testsGlob: PathFilter?

    init(testsGlob: String? = nil) {
        self.testsGlob = testsGlob.map { PathFilter([$0]) }
    }

    /// Per-declaration classification aligned with the corpus array.
    func classify(declarations: [Declaration], context: CorpusContext) -> [Bool] {
        declarations.map { isTestScoped($0, context: context) }
    }

    /// Whether one declaration is test-scoped.
    func isTestScoped(_ declaration: Declaration, context: CorpusContext) -> Bool {
        if isTestFile(declaration.location.file, context: context) {
            return true
        }
        if declaration.attributes.contains("Test") || declaration.attributes.contains("Suite") {
            return true
        }
        if declaration.kind == .function || declaration.kind == .method,
            declaration.name.hasPrefix("test")
        {
            return true
        }
        if isTestContainer(declaration, context: context) {
            return true
        }
        return context.enclosingTypeDeclarations(of: declaration)
            .contains { isTestContainer($0, context: context) }
    }

    /// Whether a type/extension declaration is a test container: `@Suite`
    /// or an `XCTestCase` descendant (transitively, within the corpus).
    private func isTestContainer(_ declaration: Declaration, context: CorpusContext) -> Bool {
        switch declaration.kind {
        case .class, .struct, .enum, .actor, .extension:
            break
        default:
            return false
        }
        if declaration.attributes.contains("Suite") {
            return true
        }
        if declaration.conformances.contains("XCTestCase") {
            return true
        }
        return context.typeTransitivelyConforms(declaration.name, to: "XCTestCase")
    }

    /// Whether a path is a test file.
    func isTestFile(_ path: String, context: CorpusContext) -> Bool {
        if let testsGlob { return testsGlob.excludes(path) }
        return context.isTestFile(path)
    }
}
