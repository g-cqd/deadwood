//  Lifted from SwiftStaticAnalysis (MIT) — Models/Reference.swift.

// MARK: - ReferenceContext

/// The context in which an identifier is referenced.
enum ReferenceContext: String, Sendable, Codable {
    /// Function or method call: `foo()`
    case call

    /// Reading a variable: `let x = foo`
    case read

    /// Writing to a variable: `foo = x`
    case write

    /// Type annotation: `let x: Foo`
    case typeAnnotation

    /// Inheritance or conformance: `class Bar: Foo`
    case inheritance

    /// Generic constraint: `where T: Foo`
    case genericConstraint

    /// Import statement: `import Foo`
    case `import`

    /// Attribute: `@Foo`
    case attribute

    /// Member access base: `foo.bar`
    case memberAccessBase

    /// Member access member: `foo.bar`
    case memberAccessMember

    /// Key path: `\Foo.bar`
    case keyPath

    /// Pattern matching: `case .foo`
    case pattern

    /// Unknown context
    case unknown
}

// MARK: - Reference

/// A reference to an identifier in source code.
struct Reference: Sendable, Hashable, Codable {
    /// The referenced identifier.
    let identifier: String

    /// Location of the reference.
    let location: SourceLocation

    /// Scope containing the reference.
    let scope: ScopeID

    /// Context of the reference.
    let context: ReferenceContext

    /// Whether this is a qualified reference (e.g. `Module.Type`).
    let isQualified: Bool

    /// The qualifier if qualified (e.g. `Module` in `Module.Type`).
    let qualifier: String?

    init(
        identifier: String,
        location: SourceLocation,
        scope: ScopeID,
        context: ReferenceContext,
        isQualified: Bool = false,
        qualifier: String? = nil
    ) {
        self.identifier = identifier
        self.location = location
        self.scope = scope
        self.context = context
        self.isQualified = isQualified
        self.qualifier = qualifier
    }
}

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
