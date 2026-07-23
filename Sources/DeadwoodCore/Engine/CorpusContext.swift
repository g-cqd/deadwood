//  New in deadwood (backing for lifted root/witness logic).
//
//  SSA associated members with their enclosing types by testing
//  `scope.id.contains(typeName)` — but scope IDs are `file:counter`, so the
//  match only ever fired when the file happened to be named after the type.
//  This resolver does the association soundly through the scope tree: every
//  type scope's location equals its type declaration's location, giving a
//  precise scope → declaration mapping.

// MARK: - CorpusContext

/// Resolves structural questions about collected facts: which type encloses
/// a declaration, what a declaration's *effective* access level is, and
/// which protocols exist in the corpus.
struct CorpusContext: Sendable {
    private let scopes: ScopeTree

    /// Type/extension declarations keyed by the location of the scope they
    /// introduce ("file:line:column").
    private let typeDeclarationByScopeStart: [String: Declaration]

    /// Nominal type declarations by name (extensions excluded).
    private let nominalTypesByName: [String: [Declaration]]

    /// Conformance lists merged across a type's declaration and all its
    /// extensions, keyed by type name.
    private let mergedConformancesByTypeName: [String: Set<String>]

    /// Names of protocols declared inside the corpus.
    let protocolNames: Set<String>

    init(result: AnalysisResult) {
        scopes = result.scopes

        var byScopeStart: [String: Declaration] = [:]
        var nominals: [String: [Declaration]] = [:]
        var conformances: [String: Set<String>] = [:]
        var protocols: Set<String> = []

        for declaration in result.declarations.declarations {
            switch declaration.kind {
            case .class, .struct, .enum, .protocol, .actor, .extension:
                byScopeStart[Self.key(declaration.location)] = declaration
                if declaration.kind == .protocol {
                    protocols.insert(declaration.name)
                }
                if declaration.kind != .extension {
                    nominals[declaration.name, default: []].append(declaration)
                }
                if !declaration.conformances.isEmpty {
                    let names = declaration.conformances.map(Self.baseName(ofConformance:))
                    conformances[declaration.name, default: []].formUnion(names)
                }
            default:
                break
            }
        }

        typeDeclarationByScopeStart = byScopeStart
        nominalTypesByName = nominals
        mergedConformancesByTypeName = conformances
        protocolNames = protocols
    }

    private static func key(_ location: SourceLocation) -> String {
        "\(location.file):\(location.line):\(location.column)"
    }

    /// Strip qualifiers and generic arguments from a conformance entry:
    /// "SwiftUI.View" -> "View", "Sequence<Int>" -> "Sequence".
    static func baseName(ofConformance conformance: String) -> String {
        let unqualified = conformance.split(separator: ".").last.map(String.init) ?? conformance
        return unqualified.split(separator: "<").first.map(String.init) ?? unqualified
    }

    // MARK: - Enclosing types

    /// Type/extension declarations lexically enclosing `declaration`,
    /// nearest first.
    func enclosingTypeDeclarations(of declaration: Declaration) -> [Declaration] {
        var result: [Declaration] = []
        for scope in scopes.chain(from: declaration.scope) where scope.kind.isTypeScope {
            if let typeDecl = typeDeclarationByScopeStart[Self.key(scope.location)] {
                result.append(typeDecl)
            }
        }
        return result
    }

    /// The nearest enclosing type or extension declaration, if any.
    func nearestEnclosingType(of declaration: Declaration) -> Declaration? {
        enclosingTypeDeclarations(of: declaration).first
    }

    /// Whether the declaration is a member of a protocol declaration
    /// (i.e. a protocol requirement).
    func isProtocolRequirement(_ declaration: Declaration) -> Bool {
        nearestEnclosingType(of: declaration)?.kind == .protocol
    }

    // MARK: - Effective access

    /// The declaration's effective access level: its declared level capped
    /// by every enclosing type's declared level. A `func` inside a
    /// `private struct` is effectively private. Extensions are resolved to
    /// the extended nominal type when the name is unambiguous; otherwise
    /// they conservatively contribute their own declared level.
    func effectiveAccess(of declaration: Declaration) -> AccessLevel {
        var access = declaration.accessLevel
        for enclosing in enclosingTypeDeclarations(of: declaration) {
            access = min(access, declaredAccess(ofTypeOrExtension: enclosing))
        }
        return access
    }

    private func declaredAccess(ofTypeOrExtension declaration: Declaration) -> AccessLevel {
        guard declaration.kind == .extension else {
            return declaration.accessLevel
        }
        // `extension Foo` caps members at Foo's declared access when Foo is
        // resolvable; unknown or ambiguous names stay conservative.
        let candidates = nominalTypesByName[declaration.name] ?? []
        if candidates.count == 1, let nominal = candidates.first {
            return max(declaration.accessLevel, nominal.accessLevel)
        }
        return max(declaration.accessLevel, .internal)
    }

    // MARK: - Conformances

    /// Conformances of the type named `name`, merged across its declaration
    /// and every extension of it in the corpus.
    func conformances(ofTypeNamed name: String) -> Set<String> {
        mergedConformancesByTypeName[name] ?? []
    }

    /// Whether the declaration is a member of a type (or extension chain)
    /// that inherits from or conforms to something declared *outside* the
    /// corpus. Such members may witness external protocol requirements or
    /// override external superclass members — usage that source-level
    /// analysis cannot see.
    func isMemberOfExternallyConformingType(_ declaration: Declaration) -> Bool {
        guard let enclosing = nearestEnclosingType(of: declaration) else {
            return false
        }
        // Default implementations inside `extension SomeProtocol` count as
        // members of that protocol for witness purposes.
        let typeName = enclosing.name
        let inherited = conformances(ofTypeNamed: typeName)
        return inherited.contains { !protocolNames.contains($0) && !nominalTypesByName.keys.contains($0) }
    }

    /// Whether the declaration sits inside a type carrying the given
    /// attribute (e.g. "resultBuilder").
    func isMemberOfType(withAttribute attribute: String, _ declaration: Declaration) -> Bool {
        enclosingTypeDeclarations(of: declaration).contains { $0.attributes.contains(attribute) }
    }
}
