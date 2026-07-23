//  Lifted from SwiftStaticAnalysis (MIT) — Models/Scope.swift.
//  Trimmed: child-links and ancestor predicates nothing here consults.

// MARK: - ScopeID

/// Unique identifier for a lexical scope.
struct ScopeID: Sendable, Hashable {
    /// The global/file scope.
    static let global = Self("global")

    /// The underlying identifier.
    let id: String

    init(_ id: String) {
        self.id = id
    }
}

// MARK: - ScopeKind

/// The kind of lexical scope.
enum ScopeKind: String, Sendable {
    case global
    case `class`
    case `struct`
    case `enum`
    case `protocol`
    case `extension`
    case function
    case closure
    case `if`
    case `guard`
    case `for`
    case `while`
    case `switch`
    case `do`
    case actor

    /// Whether the scope is introduced by a nominal type or extension.
    var isTypeScope: Bool {
        switch self {
        case .actor, .class, .enum, .extension, .protocol, .struct:
            true
        default:
            false
        }
    }
}

// MARK: - Scope

/// A lexical scope in the source code.
struct Scope: Sendable, Hashable {
    /// Unique identifier for this scope.
    let id: ScopeID

    /// The kind of scope.
    let kind: ScopeKind

    /// Name of the scope (e.g. function name, type name).
    let name: String?

    /// Parent scope ID (nil for global scope).
    let parent: ScopeID?

    /// Location where the scope begins.
    let location: SourceLocation

    init(
        id: ScopeID,
        kind: ScopeKind,
        name: String? = nil,
        parent: ScopeID? = nil,
        location: SourceLocation
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.parent = parent
        self.location = location
    }
}

// MARK: - ScopeTree

/// The scope hierarchy of the analyzed sources.
struct ScopeTree: Sendable {
    /// All scopes indexed by ID.
    private(set) var scopes: [ScopeID: Scope] = [:]

    init() {}

    /// Add a scope to the tree.
    mutating func add(_ scope: Scope) {
        scopes[scope.id] = scope
    }

    /// Get the scope for an ID.
    func scope(for id: ScopeID) -> Scope? {
        scopes[id]
    }

    /// Get the parent chain for a scope (nearest first).
    func ancestors(of id: ScopeID) -> [Scope] {
        var result: [Scope] = []
        var currentID = id

        while let scope = scopes[currentID], let parentID = scope.parent {
            if let parent = scopes[parentID] {
                result.append(parent)
                currentID = parentID
            } else {
                break
            }
        }

        return result
    }

    /// The scope itself followed by its ancestors (nearest first).
    func chain(from id: ScopeID) -> [Scope] {
        var result: [Scope] = []
        if let own = scopes[id] {
            result.append(own)
        }
        result.append(contentsOf: ancestors(of: id))
        return result
    }
}
