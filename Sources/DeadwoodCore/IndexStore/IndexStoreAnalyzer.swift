//  Lifted from SwiftStaticAnalysis (MIT) —
//  UnusedCodeDetector/IndexStore/IndexStoreAnalyzer.swift.
//  Changes during the lift:
//  - Whole file gated behind `#if canImport(IndexStoreDB)`; `SourceLocation`
//    is deadwood's model type.
//  - The `IndexStoreBasedDetector` adapter (index → `UnusedCode`) is dropped:
//    the `IndexReachabilityBridge` produces findings through deadwood's own
//    reachability pipeline, so the reference-count analyzer's job here is to
//    supply per-symbol reference counts that enrich the index-mode note.

#if canImport(IndexStoreDB)
    import Foundation

    /// Whether a path looks like a test file (built-in heuristics).
    func indexMatchesTestFilePath(_ path: String) -> Bool {
        pathMatchesTestsGlob(path) || pathMatchesTestFileSuffixGlob(path)
    }

    // MARK: - SymbolUsage

    /// Tracks usage information for one symbol from the index.
    struct SymbolUsage: Sendable {
        /// The symbol's USR.
        let usr: String
        /// The symbol name.
        let name: String
        /// The kind of symbol.
        let kind: IndexedSymbolKind
        /// Location of the definition.
        let definitionLocation: SourceLocation?
        /// Number of references (excluding the definition).
        let referenceCount: Int
        /// Whether the symbol is only referenced from its own definition scope.
        let onlySelfReferenced: Bool
        /// Whether this appears to be a test symbol.
        let isTestSymbol: Bool

        /// Whether this symbol is unused (no references at all).
        var isUnused: Bool { referenceCount == 0 }

        init(
            usr: String,
            name: String,
            kind: IndexedSymbolKind,
            definitionLocation: SourceLocation?,
            referenceCount: Int,
            onlySelfReferenced: Bool,
            isTestSymbol: Bool
        ) {
            self.usr = usr
            self.name = name
            self.kind = kind
            self.definitionLocation = definitionLocation
            self.referenceCount = referenceCount
            self.onlySelfReferenced = onlySelfReferenced
            self.isTestSymbol = isTestSymbol
        }
    }

    // MARK: - IndexStoreAnalyzer

    /// Analyzes symbol usage using the index store. A single sweep over every
    /// analysed file (`allOccurrencesByUSR`), then local lookup — O(total
    /// occurrences), not O(definitions × occurrences).
    final class IndexStoreAnalyzer: Sendable {
        private let reader: IndexStoreReader
        private let files: Set<String>

        init(reader: IndexStoreReader, files: [String]) {
            self.reader = reader
            self.files = Set(
                files.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path })
        }

        /// Analyze all symbols and return their usage information.
        func analyzeUsage() -> [SymbolUsage] {
            let occurrencesByUSR = reader.allOccurrencesByUSR(in: files)
            var usageMap: [String: SymbolUsage] = [:]
            usageMap.reserveCapacity(occurrencesByUSR.count)

            for (usr, occurrences) in occurrencesByUSR {
                guard
                    let definition = occurrences.first(where: { occ in
                        occ.roles.isDefinitionLike && files.contains(occ.file)
                    })
                else { continue }
                if shouldSkipSymbol(definition.symbol) { continue }
                usageMap[usr] = makeSymbolUsage(definition: definition, occurrences: occurrences)
            }
            return Array(usageMap.values)
        }

        /// Analyze unused symbols only.
        func findUnusedSymbols() -> [SymbolUsage] {
            analyzeUsage().filter(\.isUnused)
        }

        // MARK: - Private

        private func makeSymbolUsage(
            definition: IndexedOccurrence,
            occurrences: [IndexedOccurrence]
        ) -> SymbolUsage {
            let symbol = definition.symbol
            var referenceCount = 0
            var definitionFiles = Set<String>()
            var referenceFiles = Set<String>()

            for occ in occurrences {
                if occ.roles.isDefinitionLike { definitionFiles.insert(occ.file) }
                if occ.roles.indicatesUsage {
                    referenceCount += 1
                    referenceFiles.insert(occ.file)
                }
            }

            let onlySelfReferenced = referenceCount > 0 && referenceFiles.isSubset(of: definitionFiles)
            let isTestSymbol = indexMatchesTestFilePath(definition.file) && symbol.name.hasPrefix("test")

            return SymbolUsage(
                usr: symbol.usr,
                name: symbol.name,
                kind: symbol.kind,
                definitionLocation: SourceLocation(
                    file: definition.file, line: definition.line, column: definition.column, offset: 0),
                referenceCount: referenceCount,
                onlySelfReferenced: onlySelfReferenced,
                isTestSymbol: isTestSymbol
            )
        }

        /// Symbols excluded from usage analysis (compiler-synthesized or
        /// implicitly referenced).
        private func shouldSkipSymbol(_ symbol: IndexedSymbol) -> Bool {
            if symbol.isSystem { return true }
            let name = symbol.name
            if name.hasPrefix("$") || name.hasPrefix("_$") { return true }
            if name == "init" || name == "deinit" { return true }
            if name == "CodingKeys" { return true }
            return false
        }
    }
#endif
