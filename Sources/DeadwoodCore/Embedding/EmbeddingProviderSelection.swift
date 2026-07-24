//  Provider selection for `--experimental-embedding-confidence`, ported from
//  dolly's `SemanticDiscovery` (model auto-discovery + resolution order).
//
//  Order: explicit `--embedding-bundle` → a model shipped next to the
//  executable → Apple's on-device `NLContextualEmbedding` → the deterministic
//  fallback. Every step degrades rather than fails: the signal only annotates
//  notes, so a missing or broken model must never cost the user a run.

#if canImport(NaturalLanguage)
    import Foundation

    // MARK: - EmbeddingProviderSelection

    enum EmbeddingProviderSelection {
        /// Resolve the provider for one run, plus any stderr notes explaining a
        /// degradation. Never throws and never returns "no provider" — the
        /// deterministic provider is total.
        ///
        /// An explicit `--embedding-bundle` that fails to load is *reported*
        /// and then falls through, because the bundle is an upgrade to the
        /// scoring model rather than a requirement of the analysis.
        static func resolve(
            bundlePath: String?
        ) async -> (provider: any SemanticEmbeddingProvider, notes: [String]) {
            var notes: [String] = []

            #if canImport(CoreML)
                if let bundlePath, !bundlePath.isEmpty {
                    do {
                        let provider = try await HFSemanticEmbeddingProvider(
                            bundleDir: URL(fileURLWithPath: bundlePath), maxLength: bundleMaxLength)
                        return (provider, notes)
                    } catch {
                        notes.append(
                            "\(ToolInfo.name): --embedding-bundle at \(bundlePath) could not be "
                                + "loaded (\(error)); falling back to the on-device provider")
                    }
                } else if let bundled = bundledModelDirectory() {
                    // A model laid out next to the binary is used with no flag.
                    // A load failure here is silent: nothing was asked for, so
                    // there is nothing to report — just take the default.
                    if let provider = try? await HFSemanticEmbeddingProvider(
                        bundleDir: bundled, maxLength: bundleMaxLength)
                    {
                        return (provider, notes)
                    }
                }
            #else
                if let bundlePath, !bundlePath.isEmpty {
                    notes.append(
                        "\(ToolInfo.name): --embedding-bundle requires macOS (CoreML); "
                            + "falling back to the on-device provider")
                }
            #endif

            if #available(macOS 14.0, *) {
                if let provider = try? NLContextualSemanticEmbeddingProvider() {
                    return (provider, notes)
                }
            }
            return (DeterministicEmbeddingProvider(), notes)
        }

        /// Cap on post-tokenization sequence length for bundle providers. 128 is
        /// the MiniLM-class context window and a safe ceiling for fixed-shape
        /// Core ML exports, whose `[1, 128]` input a longer sequence overflows.
        /// Longer declaration snippets are truncated — the anomaly score reads
        /// a declaration's shape, which its opening lines already carry.
        private static let bundleMaxLength = 128

        #if canImport(CoreML)
            /// Locates a Core ML embedding bundle shipped alongside the
            /// executable, so a distribution that ships a model uses it with no
            /// flag. `DEADWOOD_EMBEDDING_BUNDLE` overrides the location for
            /// installs that separate the binary from its resources.
            ///
            /// Returns `nil` for the plain binary and for dev/test builds —
            /// whose executable directory holds no model — which leaves the
            /// on-device NLContextual default in charge.
            static func bundledModelDirectory() -> URL? {
                let executableURL =
                    (Bundle.main.executableURL
                    ?? URL(fileURLWithPath: CommandLine.arguments.first ?? ToolInfo.name))
                    .resolvingSymlinksInPath()
                return bundledModelDirectory(
                    executableDir: executableURL.deletingLastPathComponent(),
                    override: ProcessInfo.processInfo.environment["DEADWOOD_EMBEDDING_BUNDLE"])
            }

            /// Pure candidate search behind ``bundledModelDirectory()`` — no
            /// process globals, so it is unit-testable. Order: `override` (the
            /// `DEADWOOD_EMBEDDING_BUNDLE` value) → `<executableDir>/Models/MiniLM`
            /// → `<executableDir>/../share/deadwood/Models/MiniLM`. The first
            /// candidate holding a `.mlpackage`/`.mlmodelc` wins; `nil` when
            /// none do.
            static func bundledModelDirectory(executableDir: URL, override: String?) -> URL? {
                let manager = FileManager.default
                func hasModel(_ directory: URL) -> Bool {
                    guard
                        let contents = try? manager.contentsOfDirectory(
                            at: directory, includingPropertiesForKeys: nil)
                    else { return false }
                    return contents.contains {
                        $0.pathExtension == "mlpackage" || $0.pathExtension == "mlmodelc"
                    }
                }

                var candidates: [URL] = []
                if let override, !override.isEmpty {
                    candidates.append(URL(fileURLWithPath: override))
                }
                candidates.append(executableDir.appending(path: "Models/MiniLM"))
                // FHS / Homebrew-style `bin/deadwood` next to
                // `share/deadwood/Models/MiniLM`.
                candidates.append(
                    executableDir.deletingLastPathComponent()
                        .appending(path: "share/deadwood/Models/MiniLM"))

                // Resolve each candidate so a symlinked model directory reaches
                // the provider as its real path: `contentsOfDirectory` (here and
                // in the provider's own model lookup) does not traverse a URL
                // that is itself a symlink to a directory.
                return candidates.map { $0.resolvingSymlinksInPath() }.first(where: hasModel)
            }
        #endif
    }
#endif
