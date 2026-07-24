//  Lifted from SwiftStaticAnalysis (MIT) — IndexStore/IndexStoreReader.swift.
//  Changes during the lift:
//  - Whole file gated behind `#if canImport(IndexStoreDB)`; the module is
//    linked only on macOS, so the Linux build never compiles this.
//  - Types are `internal` (deadwood keeps its model layer internal) and
//    `IndexedSymbolKind.toDeclarationKind()` maps onto deadwood's own
//    `DeclarationKind`.
//  - `findLibIndexStore`'s `xcrun` fallback routes through
//    `ProcessExecutor.runUntilExit` (synchronous, env-scrubbed, no GCD)
//    instead of the async timeout path, keeping the initializer synchronous.

#if canImport(IndexStoreDB)
    import Foundation
    import IndexStoreDB

    /// Directory-existence check that avoids the
    /// `UnsafeMutablePointer<ObjCBool>` out-parameter of
    /// `fileExists(atPath:isDirectory:)` (which strict memory safety rejects).
    /// Resolves the same question through URL resource values, which are safe.
    func indexStoreDirectoryExists(atPath path: String) -> Bool {
        let isDirectory = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.isDirectoryKey]).isDirectory
        return isDirectory == true
    }

    // MARK: - IndexStoreError

    /// Errors that can occur when reading the index store.
    enum IndexStoreError: Error, Sendable {
        /// The index database could not be opened.
        case failedToOpenDatabase(underlying: any Error)
        /// The sibling `IndexDatabase/` directory does not exist and the
        /// caller did not opt into creation.
        case databaseDirectoryMissing(String)
        /// `libIndexStore.dylib` could not be located at any trusted path.
        case dylibNotFound
    }

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
        /// The path to the index store.
        let indexStorePath: String

        /// The underlying IndexStoreDB database.
        private let db: IndexStoreDB

        /// Initialize with the path to the index store directory.
        ///
        /// - Parameters:
        ///   - indexStorePath: Path to the index store (e.g.
        ///     `.build/debug/index/store`).
        ///   - libIndexStorePath: Optional path to `libIndexStore.dylib`.
        ///   - allowsDirectoryCreation: When `true`, the sibling
        ///     `IndexDatabase/` directory is created if missing.
        init(
            indexStorePath: String,
            libIndexStorePath: String? = nil,
            allowsDirectoryCreation: Bool = false
        ) throws(IndexStoreError) {
            self.indexStorePath = indexStorePath

            let libPath: String
            if let provided = libIndexStorePath {
                libPath = provided
            } else if let resolved = Self.findLibIndexStore() {
                libPath = resolved
            } else {
                throw IndexStoreError.dylibNotFound
            }

            let storePath = URL(fileURLWithPath: indexStorePath)
            let databasePath = storePath.deletingLastPathComponent()
                .appendingPathComponent("IndexDatabase")

            if allowsDirectoryCreation {
                do {
                    try FileManager.default.createDirectory(
                        at: databasePath, withIntermediateDirectories: true)
                } catch {
                    throw IndexStoreError.failedToOpenDatabase(underlying: error)
                }
            } else if !indexStoreDirectoryExists(atPath: databasePath.path) {
                throw IndexStoreError.databaseDirectoryMissing(databasePath.path)
            }

            do {
                db = try IndexStoreDB(
                    storePath: storePath.path,
                    databasePath: databasePath.path,
                    library: IndexStoreLibrary(dylibPath: libPath),
                    waitUntilDoneInitializing: true
                )
            } catch {
                throw IndexStoreError.failedToOpenDatabase(underlying: error)
            }
        }

        /// Find `libIndexStore.dylib` in the system. Each candidate is
        /// verified root-owned by `BinaryTrustChecker` before being returned.
        static func findLibIndexStore() -> String? {
            let possiblePaths = [
                "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib",
                "/Library/Developer/Toolchains/swift-latest.xctoolchain/usr/lib/libIndexStore.dylib",
                "/Library/Developer/CommandLineTools/usr/lib/libIndexStore.dylib",
            ]

            for path in possiblePaths where BinaryTrustChecker.isTrusted(at: path) {
                return path
            }

            // Fallback to xcrun. Routes through `ProcessExecutor` so the child
            // does not inherit `DEVELOPER_DIR` from the parent.
            if let result = try? ProcessExecutor.runUntilExit(
                executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: ["--find", "swift"]
            ), result.succeeded {
                let swiftPath = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !swiftPath.isEmpty {
                    let toolchainPath = URL(fileURLWithPath: swiftPath)
                        .deletingLastPathComponent()  // bin
                        .deletingLastPathComponent()  // usr
                        .appendingPathComponent("lib")
                        .appendingPathComponent("libIndexStore.dylib")
                    let resolved = toolchainPath.path
                    if BinaryTrustChecker.isTrusted(at: resolved) {
                        return resolved
                    }
                }
            }

            return nil
        }

        /// Find all occurrences of a symbol by USR.
        func findOccurrences(ofUSR usr: String) -> [IndexedOccurrence] {
            var occurrences: [IndexedOccurrence] = []
            db.forEachSymbolOccurrence(byUSR: usr, roles: .all) { occurrence in
                occurrences.append(Self.convert(occurrence))
                return true
            }
            return occurrences
        }

        /// Check if a symbol (by USR) has any references (not just
        /// definitions).
        func hasReferences(usr: String) -> Bool {
            var hasRef = false
            db.forEachSymbolOccurrence(byUSR: usr, roles: .reference) { _ in
                hasRef = true
                return false  // Stop iteration
            }
            return hasRef
        }

        /// All index occurrences across `files`, grouped by USR. Iterating
        /// each file once and grouping locally is O(total_occurrences)
        /// instead of O(definitions * total_occurrences).
        func allOccurrencesByUSR(in files: Set<String>) -> [String: [IndexedOccurrence]] {
            var byUSR: [String: [IndexedOccurrence]] = [:]
            for filePath in files {
                let occurrences = db.symbolOccurrences(inFilePath: filePath)
                for occurrence in occurrences {
                    byUSR[occurrence.symbol.usr, default: []].append(Self.convert(occurrence))
                }
            }
            return byUSR
        }

        /// Raw IndexStoreDB occurrences for one file (used by the dependency
        /// graph, which needs relations the converted form drops).
        func rawOccurrences(inFile filePath: String) -> [SymbolOccurrence] {
            db.symbolOccurrences(inFilePath: filePath)
        }

        /// Enumerate related symbol occurrences (protocol conformances,
        /// containment) — forwards the underlying IndexStoreDB query.
        func forEachRelatedOccurrence(
            byUSR usr: String,
            roles: SymbolRole,
            _ body: (SymbolOccurrence) -> Bool
        ) {
            db.forEachRelatedSymbolOccurrence(byUSR: usr, roles: roles, body)
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

        private static func convert(_ occurrence: SymbolOccurrence) -> IndexedOccurrence {
            IndexedOccurrence(
                symbol: convertSymbol(occurrence.symbol),
                file: occurrence.location.path,
                line: occurrence.location.line,
                column: occurrence.location.utf8Column,
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

    // MARK: - IndexStorePathFinder

    /// Utility for finding index store paths in a project.
    enum IndexStorePathFinder {
        /// Find the index store path for a Swift package or Xcode project.
        static func findIndexStorePath(in projectRoot: String) -> String? {
            let buildDir = URL(fileURLWithPath: projectRoot).appendingPathComponent(".build")

            let debugIndexStore =
                buildDir
                .appendingPathComponent("debug")
                .appendingPathComponent("index")
                .appendingPathComponent("store")
            if FileManager.default.fileExists(atPath: debugIndexStore.path) {
                return debugIndexStore.path
            }

            let releaseIndexStore =
                buildDir
                .appendingPathComponent("release")
                .appendingPathComponent("index")
                .appendingPathComponent("store")
            if FileManager.default.fileExists(atPath: releaseIndexStore.path) {
                return releaseIndexStore.path
            }

            // Explicit `.build/index/store` (what `--index-store-build`
            // generates via `-index-store-path .build/index/store`).
            let explicitIndexStore =
                buildDir
                .appendingPathComponent("index")
                .appendingPathComponent("store")
            if FileManager.default.fileExists(atPath: explicitIndexStore.path) {
                return explicitIndexStore.path
            }

            // Xcode DerivedData.
            let derivedData = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library")
                .appendingPathComponent("Developer")
                .appendingPathComponent("Xcode")
                .appendingPathComponent("DerivedData")

            if let contents = try? FileManager.default.contentsOfDirectory(atPath: derivedData.path) {
                let projectName = URL(fileURLWithPath: projectRoot).lastPathComponent
                let normalizedProjectName = normalizeProjectName(projectName)
                for dir in contents
                where dirMatchesProject(dir, projectName: projectName, normalizedName: normalizedProjectName) {
                    let dataStore =
                        derivedData
                        .appendingPathComponent(dir)
                        .appendingPathComponent("Index.noindex")
                        .appendingPathComponent("DataStore")

                    if let versionedPath = findVersionedIndexStore(in: dataStore) {
                        return versionedPath
                    }
                    if FileManager.default.fileExists(atPath: dataStore.path) {
                        return dataStore.path
                    }
                }
            }

            return nil
        }

        /// Find the versioned index store subdirectory (e.g. v5, v6).
        private static func findVersionedIndexStore(in dataStore: URL) -> String? {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dataStore.path)
            else { return nil }

            let versionedDirs =
                contents
                .filter { $0.hasPrefix("v") && $0.dropFirst().allSatisfy(\.isNumber) }
                .sorted { lhs, rhs in
                    (Int(lhs.dropFirst()) ?? 0) > (Int(rhs.dropFirst()) ?? 0)
                }

            for versionedDir in versionedDirs {
                let versionedPath = dataStore.appendingPathComponent(versionedDir)
                let recordsPath = versionedPath.appendingPathComponent("records")
                let unitsPath = versionedPath.appendingPathComponent("units")
                if FileManager.default.fileExists(atPath: recordsPath.path)
                    || FileManager.default.fileExists(atPath: unitsPath.path)
                {
                    return versionedPath.path
                }
            }
            return nil
        }

        /// Normalize project name to match Xcode's DerivedData convention.
        private static func normalizeProjectName(_ name: String) -> String {
            let charactersToReplace = CharacterSet(charactersIn: " -.")
            var normalized = name
            for scalar in name.unicodeScalars where charactersToReplace.contains(scalar) {
                normalized = normalized.replacingOccurrences(of: String(scalar), with: "_")
            }
            return normalized
        }

        private static func urlEncodeProjectName(_ name: String) -> String? {
            name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        }

        /// Check if a DerivedData directory name matches a project name.
        private static func dirMatchesProject(
            _ dir: String, projectName: String, normalizedName: String
        ) -> Bool {
            let components = dir.split(separator: "-", maxSplits: 1)
            guard let dirProjectName = components.first else { return false }
            let dirNameStr = String(dirProjectName)

            if dirNameStr == projectName { return true }
            if dirNameStr == normalizedName { return true }
            if let urlEncoded = urlEncodeProjectName(projectName), dirNameStr == urlEncoded {
                return true
            }
            if let decoded = dirNameStr.removingPercentEncoding, decoded == projectName {
                return true
            }
            return dir.contains(projectName) || dir.contains(normalizedName)
        }
    }
#endif
