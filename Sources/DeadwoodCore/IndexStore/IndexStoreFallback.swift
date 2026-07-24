//  Lifted from SwiftStaticAnalysis (MIT) — IndexStore/IndexStoreFallback.swift.
//  Changes during the lift:
//  - Whole file gated behind `#if canImport(IndexStoreDB)`.
//  - `AnalysisLogger` is gone (deadwood deleted it in the M1 lift); the
//    warn-on-stale path returns notes the CLI writes to stderr instead.
//  - SSA's `AnalysisModeResult`/`determineAnalysisMode` dispatched on a
//    `.indexStore` `DetectionMode` case deadwood does not have. deadwood
//    triggers index mode from the `--index-store` CLI flag, so the mode
//    selection is replaced by `resolveIndexStore`, which returns either a
//    usable index path or a typed fallback reason.
//  - Auto-build routes through the async, structured-timeout
//    `ProcessExecutor.run`.

#if canImport(IndexStoreDB)
    import Foundation

    // MARK: - IndexStoreStatus

    /// Status of the index store for analysis.
    enum IndexStoreStatus: Sendable {
        /// Index store exists and is up-to-date.
        case available(path: String)
        /// Index store exists but is stale (sources modified after indexing).
        case stale(path: String, staleFiles: [String])
        /// Index store does not exist.
        case notFound
        /// Index store exists but failed to open.
        case failed(error: String)

        /// Whether the index is usable (available, or stale with warnings).
        var isUsable: Bool {
            switch self {
            case .available, .stale: true
            case .failed, .notFound: false
            }
        }

        /// The path to the index store, if any.
        var path: String? {
            switch self {
            case .available(let path), .stale(let path, _): path
            case .failed, .notFound: nil
            }
        }
    }

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

        var description: String {
            switch self {
            case .noIndexStore:
                "no index store found; falling back to syntax reachability — run `swift build` to generate one"
            case .indexStoreFailed(let error):
                "index store failed to open (\(error)); falling back to syntax reachability"
            case .buildFailed(let error):
                "index auto-build failed (\(error)); falling back to syntax reachability"
            case .dylibNotFound:
                "libIndexStore.dylib not found on a trusted path; falling back to syntax reachability"
            }
        }
    }

    // MARK: - IndexStoreOutcome

    /// The resolution of an index-mode request: either a usable index at a
    /// path, or a typed reason the analyzer fell back to the syntax graph.
    enum IndexStoreOutcome: Sendable {
        case index(path: String, stale: [String])
        case fallback(reason: FallbackReason)
    }

    // MARK: - BuildResult

    /// Result of attempting to build the project to generate an index.
    struct BuildResult: Sendable {
        /// Whether the build succeeded.
        let success: Bool
        /// Build output (stdout + stderr).
        let output: String
        /// Duration of the build in seconds.
        let duration: TimeInterval
        /// Path to the generated index store (if successful).
        let indexStorePath: String?

        init(success: Bool, output: String, duration: TimeInterval, indexStorePath: String?) {
            self.success = success
            self.output = output
            self.duration = duration
            self.indexStorePath = indexStorePath
        }
    }

    // MARK: - FallbackConfiguration

    /// Configuration for fallback behavior.
    struct FallbackConfiguration: Sendable {
        /// Whether to build the project if the index is missing/stale.
        var autoBuild: Bool
        /// Whether to check that the index is fresh.
        var checkFreshness: Bool
        /// Whether stale files should surface as a note.
        var warnOnStale: Bool
        /// Whether the reader may create the sibling `IndexDatabase/` dir.
        var allowsIndexDatabaseCreation: Bool

        init(
            autoBuild: Bool = false,
            checkFreshness: Bool = true,
            warnOnStale: Bool = true,
            allowsIndexDatabaseCreation: Bool = true
        ) {
            self.autoBuild = autoBuild
            self.checkFreshness = checkFreshness
            self.warnOnStale = warnOnStale
            self.allowsIndexDatabaseCreation = allowsIndexDatabaseCreation
        }

        static let `default` = Self()
    }

    // MARK: - IndexStoreFallbackManager

    /// Manages index store availability and fallback strategies. All stored
    /// state is `let` after init.
    final class IndexStoreFallbackManager: Sendable {
        /// Configuration for fallback behavior.
        let configuration: FallbackConfiguration

        /// Path to `libIndexStore.dylib` (nil = discover).
        private let libIndexStorePath: String?

        init(configuration: FallbackConfiguration = .default, libIndexStorePath: String? = nil) {
            self.configuration = configuration
            self.libIndexStorePath = libIndexStorePath
        }

        // MARK: - Resolution

        /// Resolve an index-mode request into a usable index path or a typed
        /// fallback reason. Honors an explicit `--index-store-path` override,
        /// then project discovery, then (opt-in) auto-build.
        func resolveIndexStore(
            projectRoot: String,
            sourceFiles: [String],
            explicitPath: String?
        ) async -> IndexStoreOutcome {
            if let explicitPath {
                // An explicit path is trusted as-is; only its openability and
                // freshness are checked.
                return outcome(forPath: explicitPath, sourceFiles: sourceFiles)
            }

            var status = checkIndexStoreStatus(projectRoot: projectRoot, sourceFiles: sourceFiles)

            if !status.isUsable, configuration.autoBuild {
                let build = await autoBuild(projectRoot: projectRoot)
                guard build.success else {
                    return .fallback(reason: .buildFailed(error: build.output))
                }
                status = checkIndexStoreStatus(projectRoot: projectRoot, sourceFiles: sourceFiles)
            }

            switch status {
            case .available(let path):
                return .index(path: path, stale: [])
            case .stale(let path, let staleFiles):
                return .index(path: path, stale: configuration.warnOnStale ? staleFiles : [])
            case .notFound:
                return .fallback(reason: .noIndexStore)
            case .failed(let error):
                return .fallback(reason: .indexStoreFailed(error: error))
            }
        }

        /// Openability + freshness check for an explicit path.
        private func outcome(forPath path: String, sourceFiles: [String]) -> IndexStoreOutcome {
            guard indexStoreDirectoryExists(atPath: path) else {
                return .fallback(reason: .noIndexStore)
            }
            do {
                let reader = try IndexStoreReader(
                    indexStorePath: path,
                    libIndexStorePath: libIndexStorePath,
                    allowsDirectoryCreation: configuration.allowsIndexDatabaseCreation
                )
                let stale =
                    configuration.checkFreshness
                    ? staleFiles(sourceFiles: sourceFiles, reader: reader) : []
                return .index(path: path, stale: configuration.warnOnStale ? stale : [])
            } catch IndexStoreError.dylibNotFound {
                return .fallback(reason: .dylibNotFound)
            } catch {
                return .fallback(reason: .indexStoreFailed(error: "\(error)"))
            }
        }

        // MARK: - Status

        /// Check the status of the index store for a project.
        func checkIndexStoreStatus(projectRoot: String, sourceFiles: [String]) -> IndexStoreStatus {
            guard let indexStorePath = IndexStorePathFinder.findIndexStorePath(in: projectRoot) else {
                return .notFound
            }
            do {
                let reader = try IndexStoreReader(
                    indexStorePath: indexStorePath,
                    libIndexStorePath: libIndexStorePath,
                    allowsDirectoryCreation: configuration.allowsIndexDatabaseCreation
                )
                if configuration.checkFreshness {
                    let stale = staleFiles(sourceFiles: sourceFiles, reader: reader)
                    if !stale.isEmpty {
                        return .stale(path: indexStorePath, staleFiles: stale)
                    }
                }
                return .available(path: indexStorePath)
            } catch {
                return .failed(error: "\(error)")
            }
        }

        /// Files whose source is newer than their most recent index unit.
        private func staleFiles(sourceFiles: [String], reader: IndexStoreReader) -> [String] {
            var stale: [String] = []
            for path in sourceFiles {
                guard let sourceModified = fileModificationTime(path) else { continue }
                guard let indexed = reader.dateOfLatestUnit(forFile: path) else {
                    stale.append(path)  // never indexed → stale
                    continue
                }
                if sourceModified > indexed {
                    stale.append(path)
                }
            }
            return stale
        }

        private func fileModificationTime(_ path: String) -> Date? {
            let values = try? URL(fileURLWithPath: path)
                .resourceValues(forKeys: [.contentModificationDateKey])
            return values?.contentModificationDate
        }

        // MARK: - Auto build

        /// Attempt to build the project to generate/update the index store.
        func autoBuild(projectRoot: String) async -> BuildResult {
            let startTime = Date()
            let projectURL = URL(fileURLWithPath: projectRoot)
            let packageSwift = projectURL.appendingPathComponent("Package.swift")

            if FileManager.default.fileExists(atPath: packageSwift.path) {
                return await buildSPMProject(at: projectRoot, startTime: startTime)
            }
            return BuildResult(
                success: false,
                output: "no Package.swift found at \(projectRoot); auto-build supports SwiftPM projects",
                duration: Date().timeIntervalSince(startTime),
                indexStorePath: nil
            )
        }

        /// Build an SPM project with an explicit index-store path. Routes
        /// through `ProcessExecutor` so the child `swift build` does not
        /// inherit `DYLD_INSERT_LIBRARIES`, `DEVELOPER_DIR`, etc.
        private func buildSPMProject(at projectRoot: String, startTime: Date) async -> BuildResult {
            do {
                let result = try await ProcessExecutor.run(
                    executable: URL(fileURLWithPath: "/usr/bin/swift"),
                    arguments: [
                        "build", "-Xswiftc", "-index-store-path",
                        "-Xswiftc", ".build/index/store",
                    ],
                    currentDirectory: URL(fileURLWithPath: projectRoot),
                    timeout: .seconds(600)
                )
                let combined = result.stdout + result.stderr
                let indexPath =
                    result.succeeded
                    ? URL(fileURLWithPath: projectRoot).appendingPathComponent(".build/index/store").path
                    : nil
                return BuildResult(
                    success: result.succeeded,
                    output: combined,
                    duration: Date().timeIntervalSince(startTime),
                    indexStorePath: indexPath
                )
            } catch {
                return BuildResult(
                    success: false,
                    output: "failed to run swift build: \(error)",
                    duration: Date().timeIntervalSince(startTime),
                    indexStorePath: nil
                )
            }
        }
    }
#endif
