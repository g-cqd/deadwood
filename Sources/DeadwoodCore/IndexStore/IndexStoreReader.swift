//  Lifted from SwiftStaticAnalysis (MIT) — IndexStore/IndexStoreReader.swift.
//  Changes during the lift:
//  - Whole file gated behind `#if canImport(IndexStoreDB)`; the module is
//    linked only on macOS, so the Linux build never compiles this.
//  - Types are `internal` (deadwood keeps its model layer internal) and
//    `IndexedSymbolKind.toDeclarationKind()` maps onto deadwood's own
//    `DeclarationKind`.
//  - Toolchain resolution and trust now delegate to analyzerkit's IndexStoreSupport (roadmap 0009).

import SymbolFacts

#if canImport(IndexStoreDB)
    import Foundation
    import IndexStoreDB
    import IndexStoreSupport
    import ProjectModel

    // MARK: - IndexedSymbol

    /// Information about a symbol from the index store.
    struct IndexedSymbol: Sendable {
        /// The symbol's USR (Unique Symbol Reference).
        let usr: String

        /// The symbol name.
        let name: String

        /// The kind of symbol.
        let kind: IndexedSymbolKind

        /// Whether this is a system symbol.
        let isSystem: Bool

        init(usr: String, name: String, kind: IndexedSymbolKind, isSystem: Bool) {
            self.usr = usr
            self.name = name
            self.kind = kind
            self.isSystem = isSystem
        }
    }

    // MARK: - IndexedSymbolKind

    /// Kinds of symbols in the index store.
    enum IndexedSymbolKind: String, Sendable {
        case `class`
        case `struct`
        case `enum`
        case `protocol`
        case `extension`
        case function
        case method
        case property
        case variable
        case parameter
        case `typealias`
        case module
        case unknown

        /// Convert from IndexStoreDB's `IndexSymbolKind`.
        init(from kind: IndexSymbolKind) {
            switch kind {
            case .class: self = .class
            case .struct: self = .struct
            case .enum: self = .enum
            case .protocol: self = .protocol
            case .extension: self = .extension
            case .classMethod, .instanceMethod, .staticMethod:
                self = .method
            case .function:
                self = .function
            case .classProperty, .instanceProperty, .staticProperty:
                self = .property
            case .variable:
                self = .variable
            case .parameter:
                self = .parameter
            case .typealias:
                self = .typealias
            case .module:
                self = .module
            default:
                self = .unknown
            }
        }

        /// Convert to deadwood's `DeclarationKind`.
        func toDeclarationKind() -> DeclarationKind {
            switch self {
            case .class: .class
            case .struct: .struct
            case .enum: .enum
            case .protocol: .protocol
            case .extension: .extension
            case .function: .function
            case .method: .method
            case .property, .variable: .variable
            case .parameter: .parameter
            case .typealias: .typealias
            case .module: .import
            case .unknown: .variable
            }
        }
    }

    // MARK: - IndexedOccurrence

    /// Information about where a symbol occurs in the codebase.
    struct IndexedOccurrence: Sendable {
        /// The symbol.
        let symbol: IndexedSymbol

        /// File path where the occurrence is.
        let file: String

        /// Line number.
        let line: Int

        /// Column number.
        let column: Int

        /// The roles of this occurrence (definition, reference, call, etc.).
        let roles: IndexedSymbolRoles

        init(symbol: IndexedSymbol, file: String, line: Int, column: Int, roles: IndexedSymbolRoles) {
            self.symbol = symbol
            self.file = file
            self.line = line
            self.column = column
            self.roles = roles
        }
    }

    // MARK: - IndexedSymbolRoles

    /// Roles a symbol can have in an occurrence.
    struct IndexedSymbolRoles: OptionSet, Sendable {
        let rawValue: UInt64

        init(rawValue: UInt64) {
            self.rawValue = rawValue
        }

        static let declaration = Self(rawValue: 1 << 0)
        static let definition = Self(rawValue: 1 << 1)
        static let reference = Self(rawValue: 1 << 2)
        static let read = Self(rawValue: 1 << 3)
        static let write = Self(rawValue: 1 << 4)
        static let call = Self(rawValue: 1 << 5)
        static let dynamic = Self(rawValue: 1 << 6)
        static let implicit = Self(rawValue: 1 << 7)

        /// Whether the occurrence represents a declaration site.
        var isDefinitionLike: Bool {
            contains(.definition) || contains(.declaration)
        }

        /// Whether the occurrence represents an actual use-site.
        var indicatesUsage: Bool {
            contains(.reference) || contains(.call) || contains(.read) || contains(.write)
        }
    }

    // MARK: - IndexStoreReader

    /// Reads symbol information from a Swift index store.
    ///
    /// ## SAFETY
    ///
    /// `@unchecked Sendable` is sound because `IndexStoreDB` is documented
    /// thread-safe for concurrent reads, `db` is set once in `init` and never
    /// mutated, and every method here is a read-only query.
    final class IndexStoreReader: @unchecked Sendable {
        /// The store's root, canonical.
        let indexStorePath: String

        /// The session the reader queries: the store opened by analyzerkit (ADR-0004), its database under the cache
        /// root, and how it covered the analyzed files.
        let session: IndexStoreSession

        /// The underlying IndexStoreDB database.
        private var db: IndexStoreDB { session.database }

        /// analyzerkit's queries over the database (roadmap 0054): paths in the corpus's spelling.
        private let queries: IndexQueries

        init(session: IndexStoreSession) {
            self.session = session
            indexStorePath = session.store
            queries = IndexQueries(session: session)
        }

        /// analyzerkit's ordered, audited resolution of `libIndexStore.dylib`.
        static func findLibIndexStore() async -> String? {
            await ToolchainResolution.resolve().libraryPath
        }

        /// Find all occurrences of a symbol by USR.
        func findOccurrences(ofUSR usr: String) -> [IndexedOccurrence] {
            queries.occurrences(ofUSR: usr).map(Self.convert)
        }

        /// Check if a symbol (by USR) has any references (not just
        /// definitions).
        func hasReferences(usr: String) -> Bool {
            queries.hasOccurrences(ofUSR: usr, roles: .reference)
        }

        /// All index occurrences across `files`, grouped by USR. Iterating
        /// each file once and grouping locally is O(total_occurrences)
        /// instead of O(definitions * total_occurrences).
        func allOccurrencesByUSR(in files: Set<String>) -> [String: [IndexedOccurrence]] {
            var byUSR: [String: [IndexedOccurrence]] = [:]
            for filePath in files {
                IndexQueryCounter.current?.countQuery()
                for occurrence in queries.occurrences(inFile: filePath) {
                    byUSR[occurrence.usr, default: []].append(Self.convert(occurrence))
                }
            }
            return byUSR
        }

        /// One file's occurrences, IndexStoreDB's records with the file in the corpus's spelling (used by the dependency
        /// graph, which needs relations the converted form drops).
        func occurrences(inFile filePath: String) -> [IndexQueries.Occurrence] {
            IndexQueryCounter.current?.countQuery()
            return queries.occurrences(inFile: filePath)
        }

        /// Poll for changes to the index.
        func pollForChanges() {
            db.pollForUnitChangesAndWait()
        }

        /// Timestamp of the most recent index unit recorded for `filePath`,
        /// used by the freshness check to spot sources edited after indexing.
        func dateOfLatestUnit(forFile filePath: String) -> Date? {
            db.dateOfLatestUnitFor(filePath: filePath)
        }

        // MARK: - Private helpers

        private static func convert(_ occurrence: IndexQueries.Occurrence) -> IndexedOccurrence {
            IndexedOccurrence(
                symbol: convertSymbol(occurrence.record.symbol),
                file: occurrence.file,
                line: occurrence.line,
                column: occurrence.column,
                roles: convertRoles(occurrence.roles)
            )
        }

        private static func convertSymbol(_ symbol: Symbol) -> IndexedSymbol {
            IndexedSymbol(
                usr: symbol.usr,
                name: symbol.name,
                kind: IndexedSymbolKind(from: symbol.kind),
                isSystem: false  // IndexStoreDB doesn't expose this directly
            )
        }

        private static func convertRoles(_ roles: SymbolRole) -> IndexedSymbolRoles {
            var result = IndexedSymbolRoles()
            if roles.contains(.declaration) { result.insert(.declaration) }
            if roles.contains(.definition) { result.insert(.definition) }
            if roles.contains(.reference) { result.insert(.reference) }
            if roles.contains(.read) { result.insert(.read) }
            if roles.contains(.write) { result.insert(.write) }
            if roles.contains(.call) { result.insert(.call) }
            if roles.contains(.dynamic) { result.insert(.dynamic) }
            if roles.contains(.implicit) { result.insert(.implicit) }
            return result
        }
    }
#endif
