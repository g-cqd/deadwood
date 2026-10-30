//  Lifted from SwiftStaticAnalysis (MIT) — IndexStore/IndexStoreFallback.swift.
//  Changes since the lift:
//  - Whole file gated behind `#if canImport(IndexStoreDB)`.
//  - Mode selection is `resolveIndexStore`, which returns an open reader or a typed fallback reason.
//  - Stores are found and named by analyzerkit's `IndexStoreLocation`, opened by its `IndexStoreSession` (database
//    under the cache root, coverage of the analyzed files), and built by its `BoundedProcess` (roadmap 0019, ADR-0004).

#if canImport(IndexStoreDB)
    import Foundation
    import IndexStoreSupport
    import ProjectModel

    // MARK: - FallbackReason

    /// Reason for falling back to syntax-based analysis.
    enum FallbackReason: Sendable, CustomStringConvertible {
        /// No index store found.
        case noIndexStore
        /// Index store failed to open.
        case indexStoreFailed(error: String)
        /// Auto-build was attempted but failed.
        case buildFailed(error: String)
        /// The `libIndexStore.dylib` needed to read an index was not found.
        case dylibNotFound
        /// The given path holds no index records (a DerivedData or `Index.noindex` directory, a wrong path).
        case notAnIndexStore(path: String)
        /// The store indexes none of the analyzed files as they are now: never indexed, or all changed since.
        case coversNoAnalyzedFile(store: String, analyzedCount: Int)

        var description: String {
            switch self {
            case .noIndexStore:
                "warning: no index store found; falling back to name-based reachability, which can conflate "
                    + "same-named declarations across modules. For an Xcode project pass --index-store-path "
                    + "<DerivedData>/<Project>-<hash>/Index.noindex/DataStore (after xcodebuild build or test); "
                    + "for a package run swift build first."
            case .indexStoreFailed(let error):
                "warning: index store failed to open (\(error)); falling back to name-based reachability, which "
                    + "can conflate same-named declarations across modules. Rebuild the project (swift build, or "
                    + "xcodebuild build for an Xcode project), or pass --index-store-path to a readable index store."
            case .buildFailed(let error):
                "warning: index auto-build failed (\(error)); falling back to name-based reachability, which can "
                    + "conflate same-named declarations across modules. Fix the build errors and run again, or pass "
                    + "--index-store-path to an existing index store."
            case .notAnIndexStore(let path):
                "warning: \(path) is not an index store (no records in it, or in a vN directory below it); falling "
                    + "back to name-based reachability, which can conflate same-named declarations across modules. "
                    + "Pass the store directory itself, e.g. <DerivedData>/Index.noindex/DataStore."
            case .coversNoAnalyzedFile(let store, let count):
                "warning: index at \(store) indexes none of the \(count) analyzed file(s) as they are now; falling back "
                    + "to name-based reachability, which can conflate same-named declarations across modules. Rebuild "
                    + "the project (swift build, or xcodebuild build for an Xcode project) and run again."
            case .dylibNotFound:
                "warning: libIndexStore.dylib not found on a trusted path; falling back to name-based reachability, "
                    + "which can conflate same-named declarations across modules. Install Xcode or a Swift toolchain "
                    + "that ships libIndexStore.dylib, then run again."
            }
        }
    }

    // MARK: - IndexStoreOutcome

    /// The resolution of an index-mode request: either an open index and the analyzed files it is stale for, or a
    /// typed reason the analyzer fell back to the syntax graph.
    enum IndexStoreOutcome: Sendable {
        case index(IndexStoreReader, stale: [String])
        case fallback(reason: FallbackReason)
    }

    // MARK: - BuildResult

    /// Result of attempting to build the project to generate an index.
    struct BuildResult: Sendable {
        /// Whether the build succeeded.
        let success: Bool
        /// Build output (stdout + stderr).
        let output: String
    }

    // MARK: - FallbackConfiguration

    /// Configuration for fallback behavior.
    struct FallbackConfiguration: Sendable {
        /// Whether to build the project if the index is missing.
        var autoBuild: Bool
        /// Whether stale files should be reported (and their findings dropped).
        var warnOnStale: Bool

        init(autoBuild: Bool = false, warnOnStale: Bool = true) {
            self.autoBuild = autoBuild
            self.warnOnStale = warnOnStale
        }

        static let `default` = Self()
    }

    // MARK: - IndexStoreFallbackManager

    /// Finds, builds (opt-in) and opens the index store for a run. All stored state is `let` after init.
    final class IndexStoreFallbackManager: Sendable {
        /// Configuration for fallback behavior.
        let configuration: FallbackConfiguration

        /// Path to `libIndexStore.dylib` (nil = analyzerkit's resolution).
        private let libIndexStorePath: String?

        /// Where the Xcode DerivedData stores are looked for.
        private let derivedDataRoots: [String]

        init(
            configuration: FallbackConfiguration = .default, libIndexStorePath: String? = nil,
            derivedDataRoots: [String]? = nil
        ) {
            self.configuration = configuration
            self.libIndexStorePath = libIndexStorePath
            self.derivedDataRoots =
                derivedDataRoots ?? [
                    (ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory())
                        + "/Library/Developer/Xcode/DerivedData"
                ]
        }

        // MARK: - Resolution

        /// Resolve an index-mode request into an open index or a typed fallback reason. Honors an explicit
        /// `--index-store-path`, then discovery, then (opt-in) auto-build. The database lives under `cacheRoot`.
        func resolveIndexStore(
            projectRoot: String,
            sourceFiles: [String],
            explicitPath: String?,
            cacheRoot: String
        ) async -> IndexStoreOutcome {
            let store: String
            if let explicitPath {
                // A path that is not a store is refused before anything opens it: libIndexStore would create a `v5/`
                // in it (analyzerkit roadmap 0035, probe D1).
                switch IndexStoreLocation.resolve(explicitPath) {
                case .store(let resolved): store = resolved
                case .notAStore:
                    let isDirectory =
                        (try? URL(fileURLWithPath: explicitPath).resourceValues(forKeys: [.isDirectoryKey]))?
                        .isDirectory == true
                    return .fallback(reason: isDirectory ? .notAnIndexStore(path: explicitPath) : .noIndexStore)
                }
            } else if let found = discover(projectRoot: projectRoot) {
                store = found
            } else if configuration.autoBuild {
                let build = await autoBuild(projectRoot: projectRoot)
                guard build.success else { return .fallback(reason: .buildFailed(error: build.output)) }
                guard let built = discover(projectRoot: projectRoot) else { return .fallback(reason: .noIndexStore) }
                store = built
            } else {
                return .fallback(reason: .noIndexStore)
            }

            guard let library = await resolvedLibrary() else { return .fallback(reason: .dylibNotFound) }
            IndexQueryCounter.current?.countOpen()
            switch IndexStoreSession.open(store, cacheRoot: cacheRoot, library: library, analyzedFiles: sourceFiles) {
            case .usable(let session):
                // A file the index never saw, or saw before it last changed; an unreadable one is not judged.
                let stale = session.coverage.files.filter {
                    $0.coverage == .notIndexed || $0.coverage == .changedSinceBuild
                }
                .map(\.path)
                return .index(IndexStoreReader(session: session), stale: configuration.warnOnStale ? stale : [])
            case .notUsable(let store, _):
                return .fallback(reason: .coversNoAnalyzedFile(store: store, analyzedCount: sourceFiles.count))
            case .notAStore:
                return .fallback(reason: .notAnIndexStore(path: store))
            case .failed(let reason):
                return .fallback(
                    reason: reason.contains("not trusted") ? .dylibNotFound : .indexStoreFailed(error: reason))
            }
        }

        /// The store a project has: SwiftPM's under its `.build` (each configuration, under each target triple, and
        /// the Swift Build system's `out`), then the newest DerivedData store of its containers.
        func discover(projectRoot: String) -> String? {
            guard let layout = ProjectLayout.discover(paths: [projectRoot]) else { return nil }
            return IndexStoreLocation.discover(layout: layout, derivedDataRoots: derivedDataRoots)
        }

        private func resolvedLibrary() async -> String? {
            if let libIndexStorePath { return libIndexStorePath }
            return await IndexStoreReader.findLibIndexStore()
        }

        // MARK: - Auto build

        /// `swift build` a SwiftPM project to generate the index store, through analyzerkit's `BoundedProcess`: a
        /// scrubbed environment (no inherited `DYLD_INSERT_LIBRARIES` or `DEVELOPER_DIR`), a deadline, and a process
        /// group terminated whole when it passes.
        func autoBuild(projectRoot: String) async -> BuildResult {
            guard FileManager.default.fileExists(atPath: projectRoot + "/Package.swift") else {
                return BuildResult(
                    success: false,
                    output: "no Package.swift found at \(projectRoot); auto-build supports SwiftPM projects")
            }
            do {
                let result = try await BoundedProcess.run(
                    "/usr/bin/swift", ["build", "-Xswiftc", "-index-store-path", "-Xswiftc", ".build/index/store"],
                    directory: projectRoot,
                    environment: BoundedProcess.scrubbedEnvironment(source: ProcessInfo.processInfo.environment),
                    timeout: .seconds(600))
                return BuildResult(
                    success: result.succeeded, output: result.standardOutputText + result.standardErrorText)
            } catch {
                return BuildResult(success: false, output: "failed to run swift build: \(error)")
            }
        }
    }
#endif
