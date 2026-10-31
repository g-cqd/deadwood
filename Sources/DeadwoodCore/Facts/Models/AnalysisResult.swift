//  Lifted from SwiftStaticAnalysis (MIT) — Models/AnalysisResult.swift.
//  Trimmed: `AnalysisStatistics` (decorative) and `AnalysisError`
//  (deadwood's typed failure surface is `DeadwoodError`; parsing itself is
//  error-tolerant and never throws).

import ProjectModel
import SymbolFacts

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

    /// Test code, by its project's targets or its content (ADR-0024): what production mode leaves out.
    let testFiles: Set<String>

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
        testFiles: Set<String> = [],
        regionSpansByFile: [String: [CodeRegionSpan]] = [:]
    ) {
        self.files = files
        self.declarations = declarations
        self.references = references
        self.scopes = scopes
        self.stringLiteralOccurrences = stringLiteralOccurrences
        self.commentTokens = commentTokens
        self.generatedFiles = generatedFiles
        self.testFiles = testFiles
        self.regionSpansByFile = regionSpansByFile
    }
}

// MARK: - FileAnalysisResult

/// Collected facts for a single file.
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
    /// Whether a generator wrote this file: its content, joined with its project per run.
    var isGenerated: Bool
    /// Whether this file is test code: its content, joined with its project per run.
    var isTestCode: Bool
    /// What the file's content alone says of its region (``ProjectModel/ProjectClassification/contentRegion(path:tree:)``):
    /// the part a cache keyed by content may keep.
    let contentRegion: UInt8
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
        isTestCode: Bool = false,
        contentRegion: UInt8? = nil,
        regionSpans: [CodeRegionSpan] = []
    ) {
        self.file = file
        self.declarations = declarations
        self.references = references
        self.scopes = scopes
        self.stringLiteralTokens = stringLiteralTokens
        self.commentTokens = commentTokens
        self.isGenerated = isGenerated
        self.isTestCode = isTestCode
        var content: CodeRegion = []
        if isGenerated { content.insert(.generated) }
        if isTestCode { content.insert(.test) }
        self.contentRegion = contentRegion ?? content.rawValue
        self.regionSpans = regionSpans
    }
}
