//  Lifted from SwiftStaticAnalysis (MIT) — Models/AnalysisResult.swift.
//  Trimmed: `AnalysisStatistics` (decorative) and `AnalysisError`
//  (deadwood's typed failure surface is `DeadwoodError`; parsing itself is
//  error-tolerant and never throws).

import AemiJSON

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

    /// Where each identifier-shaped token appears inside a string literal,
    /// outside generated files (dynamic-reference demotion set).
    let stringLiteralOccurrences: [String: [SourceLocation]]

    /// Identifier-shaped tokens appearing in comments anywhere in the corpus.
    let commentTokens: Set<String>

    /// Files a generator wrote: their code counts as uses, but nothing in
    /// them is reported.
    let generatedFiles: Set<String>

    /// Per file, the lines only debug builds or previews compile.
    let regionSpansByFile: [String: [CodeRegionSpan]]

    init(
        files: [String],
        declarations: DeclarationIndex,
        references: ReferenceIndex,
        scopes: ScopeTree,
        stringLiteralOccurrences: [String: [SourceLocation]] = [:],
        commentTokens: Set<String> = [],
        generatedFiles: Set<String> = [],
        regionSpansByFile: [String: [CodeRegionSpan]] = [:]
    ) {
        self.files = files
        self.declarations = declarations
        self.references = references
        self.scopes = scopes
        self.stringLiteralOccurrences = stringLiteralOccurrences
        self.commentTokens = commentTokens
        self.generatedFiles = generatedFiles
        self.regionSpansByFile = regionSpansByFile
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
    let stringLiteralTokens: Set<TokenLine>
    /// Identifier-shaped tokens inside this file's comments.
    let commentTokens: Set<String>
    /// Whether a generator wrote this file.
    let isGenerated: Bool
    /// The lines only debug builds or previews compile.
    let regionSpans: [CodeRegionSpan]

    init(
        file: String,
        declarations: [Declaration],
        references: [Reference],
        scopes: [Scope],
        stringLiteralTokens: Set<TokenLine> = [],
        commentTokens: Set<String> = [],
        isGenerated: Bool = false,
        regionSpans: [CodeRegionSpan] = []
    ) {
        self.file = file
        self.declarations = declarations
        self.references = references
        self.scopes = scopes
        self.stringLiteralTokens = stringLiteralTokens
        self.commentTokens = commentTokens
        self.isGenerated = isGenerated
        self.regionSpans = regionSpans
    }
}
