import Foundation

@testable import DeadwoodCore

/// Collect facts from an in-memory source, aggregated as a one-file corpus.
func makeFacts(_ source: String, file: String = "test.swift") -> AnalysisResult {
    StaticAnalyzer.aggregate(
        [StaticAnalyzer().collectFacts(source: source, file: file)],
        files: [file]
    )
}

/// Build a bare declaration for graph/root tests.
func makeDecl(
    name: String,
    kind: DeclarationKind,
    access: AccessLevel = .internal,
    modifiers: DeclarationModifiers = [],
    line: Int = 1,
    file: String = "test.swift",
    conformances: [String] = [],
    attributes: [String] = []
) -> Declaration {
    let location = SourceLocation(file: file, line: line, column: 1, offset: 0)
    let range = SourceRange(start: location, end: location)
    return Declaration(
        name: name,
        kind: kind,
        accessLevel: access,
        modifiers: modifiers,
        location: location,
        range: range,
        scope: .global,
        conformances: conformances,
        attributes: attributes
    )
}

/// A corpus context over just the given declarations (global scope).
func makeContext(_ declarations: [Declaration] = []) -> CorpusContext {
    var index = DeclarationIndex()
    for declaration in declarations {
        index.add(declaration)
    }
    let result = AnalysisResult(
        files: ["test.swift"],
        declarations: index,
        references: ReferenceIndex(),
        scopes: ScopeTree()
    )
    return CorpusContext(result: result)
}
