//  Lifted from SwiftStaticAnalysis (MIT) — Models/AnalysisResult.swift.
//  Trimmed: `AnalysisStatistics` (decorative) and `AnalysisError`
//  (deadwood's typed failure surface is `DeadwoodError`; parsing itself is
//  error-tolerant and never throws).

import ADJSON

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

    /// Identifier-shaped tokens appearing inside string literals anywhere
    /// in the corpus (dynamic-reference demotion set).
    let stringLiteralTokens: Set<String>

    init(
        files: [String],
        declarations: DeclarationIndex,
        references: ReferenceIndex,
        scopes: ScopeTree,
        stringLiteralTokens: Set<String> = []
    ) {
        self.files = files
        self.declarations = declarations
        self.references = references
        self.scopes = scopes
        self.stringLiteralTokens = stringLiteralTokens
    }
}

// MARK: - FileAnalysisResult

/// Collected facts for a single file.
@JSONCodable
struct FileAnalysisResult: Sendable, Codable {
    /// The file path.
    let file: String

    /// Declarations in this file.
    let declarations: [Declaration]

    /// References in this file.
    let references: [Reference]

    /// Scopes in this file.
    let scopes: [Scope]

    /// Identifier-shaped tokens inside this file's string literals.
    let stringLiteralTokens: Set<String>

    init(
        file: String,
        declarations: [Declaration],
        references: [Reference],
        scopes: [Scope],
        stringLiteralTokens: Set<String> = []
    ) {
        self.file = file
        self.declarations = declarations
        self.references = references
        self.scopes = scopes
        self.stringLiteralTokens = stringLiteralTokens
    }
}
