//  Provider selection for `--experimental-embedding-confidence`, ported from
//  dolly's `SemanticDiscovery` (model auto-discovery + resolution order).
//
//  Order: explicit `--embedding-bundle` → a model shipped next to the
//  executable → Apple's on-device `NLContextualEmbedding` → the deterministic
//  fallback. Every step degrades rather than fails: the signal only annotates
//  notes, so a missing or broken model must never cost the user a run.

#if canImport(NaturalLanguage)
    import Foundation
    import SemanticEmbedding

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
                            bundleDir: URL(fileURLWithPath: bundlePath),
                            maxLength: bundleMaxLength
                        )
                        return (provider, notes)
                    } catch {
                        notes.append(
                            "\(ToolInfo.name): --embedding-bundle at \(bundlePath) could not be "
                                + "loaded (\(error)); falling back to the on-device provider"
                        )
                    }
                } else if let bundled = EmbeddingBundleLocator.directory(tool: ToolInfo.name) {
                    // A model laid out next to the binary is used with no flag.
                    // A load failure here is silent: nothing was asked for, so
                    // there is nothing to report — just take the default.
                    if let provider = try? await HFSemanticEmbeddingProvider(
                        bundleDir: bundled,
                        maxLength: bundleMaxLength
                    ) {
                        return (provider, notes)
                    }
                }
            #else
                if let bundlePath, !bundlePath.isEmpty {
                    notes.append(
                        "\(ToolInfo.name): --embedding-bundle requires macOS (CoreML); "
                            + "falling back to the on-device provider"
                    )
                }
            #endif

            return (SemanticEmbeddingProviders.onDeviceOrFallback(), notes)
        }

        /// Cap on post-tokenization sequence length for bundle providers. 128 is
        /// the MiniLM-class context window and a safe ceiling for fixed-shape
        /// Core ML exports, whose `[1, 128]` input a longer sequence overflows.
        /// Longer declaration snippets are truncated — the anomaly score reads
        /// a declaration's shape, which its opening lines already carry.
        private static let bundleMaxLength = 128
    }
#endif
