import AemiJSON

/// A file's facts with cache-only references that omit repeated or unused fields.
@JSONCodable
struct CachedFileFacts: Sendable, Codable {
    let file: String
    let declarations: [Declaration]
    let references: [CachedReference]
    let scopes: [Scope]
    let stringLiteralTokens: Set<String>

    init(
        file: String,
        declarations: [Declaration],
        references: [CachedReference],
        scopes: [Scope],
        stringLiteralTokens: Set<String>
    ) {
        self.file = file
        self.declarations = declarations
        self.references = references
        self.scopes = scopes
        self.stringLiteralTokens = stringLiteralTokens
    }

    init(_ facts: FileAnalysisResult) {
        file = facts.file
        declarations = facts.declarations
        references = facts.references.map(CachedReference.init)
        scopes = facts.scopes
        stringLiteralTokens = facts.stringLiteralTokens
    }

    func restored() -> FileAnalysisResult {
        FileAnalysisResult(
            file: file,
            declarations: declarations,
            references: references.map { $0.restored(in: file) },
            scopes: scopes,
            stringLiteralTokens: stringLiteralTokens
        )
    }
}
