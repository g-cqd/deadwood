//  Lifted from SwiftStaticAnalysis (MIT) — Models/AnalysisResult.swift.
//  Trimmed: `AnalysisStatistics` (decorative) and `AnalysisError`
//  (deadwood's typed failure surface is `DeadwoodError`; parsing itself is
//  error-tolerant and never throws).

// MARK: - AnalysisResult

/// Complete collected facts for an analyzed corpus.
struct AnalysisResult: Sendable {
    /// All files analyzed.
    let files: [String]

    /// All declarations found.
    let declarations: DeclarationIndex

    /// All references found.
    let references: ReferenceIndex

    /// Scope hierarchy.
    let scopes: ScopeTree

    init(
        files: [String],
        declarations: DeclarationIndex,
        references: ReferenceIndex,
        scopes: ScopeTree
    ) {
        self.files = files
        self.declarations = declarations
        self.references = references
        self.scopes = scopes
    }
}

// MARK: - FileAnalysisResult

/// Collected facts for a single file.
struct FileAnalysisResult: Sendable {
    /// The file path.
    let file: String

    /// Declarations in this file.
    let declarations: [Declaration]

    /// References in this file.
    let references: [Reference]

    /// Scopes in this file.
    let scopes: [Scope]

    init(
        file: String,
        declarations: [Declaration],
        references: [Reference],
        scopes: [Scope]
    ) {
        self.file = file
        self.declarations = declarations
        self.references = references
        self.scopes = scopes
    }
}
