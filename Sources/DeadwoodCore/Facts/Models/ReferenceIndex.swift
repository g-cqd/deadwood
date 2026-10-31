//  deadwood's index of analyzerkit's `SymbolFacts` references (roadmap 0055).

import SymbolFacts

// MARK: - ReferenceIndex

/// Index of references for fast lookup.
struct ReferenceIndex: Sendable {
    /// All references.
    private(set) var references: [Reference] = []

    /// References indexed by identifier.
    private(set) var byIdentifier: [String: [Reference]] = [:]

    /// References indexed by file.
    private(set) var byFile: [String: [Reference]] = [:]

    init() {}

    /// All unique referenced identifiers.
    var uniqueIdentifiers: Set<String> {
        Set(byIdentifier.keys)
    }

    /// Add a reference to the index.
    mutating func add(_ reference: Reference) {
        references.append(reference)
        byIdentifier[reference.identifier, default: []].append(reference)
        byFile[reference.location.file, default: []].append(reference)
    }

    /// Find references to an identifier.
    func find(identifier: String) -> [Reference] {
        byIdentifier[identifier] ?? []
    }

    /// Find references in a specific file.
    func find(inFile file: String) -> [Reference] {
        byFile[file] ?? []
    }
}
