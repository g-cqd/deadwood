//  deadwood's additions to analyzerkit's `SymbolFacts` declarations (roadmap 0055): the index and the top-level-code
//  nodes deadwood synthesizes.

import SymbolFacts

/// The facts' location types under the names deadwood's code has always used; SwiftSyntax declares a
/// `SourceLocation` too, and this module's name wins over it.
typealias SourceLocation = SymbolLocation
typealias SourceRange = SymbolRange

// MARK: - DeclarationIndex

/// Index of declarations for fast lookup.
struct DeclarationIndex: Sendable {
    /// All declarations.
    private(set) var declarations: [Declaration] = []

    /// Declarations indexed by kind.
    private(set) var byKind: [DeclarationKind: [Declaration]] = [:]

    init() {}

    /// Add a declaration to the index.
    mutating func add(_ declaration: Declaration) {
        declarations.append(declaration)
        byKind[declaration.kind, default: []].append(declaration)
    }

    /// Find declarations of a specific kind.
    func find(kind: DeclarationKind) -> [Declaration] {
        byKind[kind] ?? []
    }
}

// MARK: - Top-level code

extension Declaration {
    /// Name of the node synthesized for a `#Preview` expansion.
    static let previewCodeName = "#Preview"

    /// Name of the node synthesized for file-scope statements.
    static let topLevelStatementsName = "top-level code"

    /// The name as findings show it: `fetch(id:)` for a function.
    var displayName: String {
        signature.map { name + $0.selectorString } ?? name
    }

    /// Whether this is the node synthesized for a `#Preview` expansion.
    var isPreviewCode: Bool {
        kind == .topLevelCode && name == Self.previewCodeName
    }
}
