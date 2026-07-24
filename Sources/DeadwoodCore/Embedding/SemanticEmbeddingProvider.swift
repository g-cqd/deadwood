//  Lifted from SwiftStaticAnalysis (MIT) —
//  DuplicationDetector/Semantic/SemanticEmbeddingProvider.swift.
//  Changes during the lift:
//  - Gated behind `#if canImport(NaturalLanguage)`: the experimental
//    embedding-confidence signal is built on the NL contextual embedding, so
//    the whole substrate is macOS-oriented and absent where NL is unavailable
//    (Linux), where the CLI flag reports itself unavailable.
//  - Types are `internal` (deadwood convention).
//  - The HuggingFace / Core ML provider came over later (0.5.0), because
//    NLContextualEmbedding is an ENGLISH natural-language model rather than a
//    code-trained one: on code it over-clusters, which blunts the anomaly
//    spread. `HFSemanticEmbeddingProvider` is the opt-in, macOS-only escape
//    hatch to a code-trained bundle; the system provider stays the default.

#if canImport(NaturalLanguage)
    import Foundation

    // MARK: - SemanticEmbeddingProvider

    /// Produces dense vector embeddings of code snippets. deadwood uses these
    /// only for the experimental `--experimental-embedding-confidence` signal:
    /// an unused-candidate whose declaration snippet is a semantic *outlier*
    /// among the other candidates is more likely to be genuinely dead, so the
    /// finding note is annotated with a kNN anomaly score. It never changes
    /// which findings fire.
    protocol SemanticEmbeddingProvider: Sendable {
        /// Dimension of every embedding this provider returns.
        var embeddingDimension: Int { get }

        /// Human-readable identity of the model that actually ran, surfaced in
        /// the stderr note and in every annotated finding. Which model produced
        /// a score changes how the score should be read, so a run must never
        /// leave that implicit.
        var providerName: String { get }

        /// Embed a code snippet into a dense vector.
        func embed(snippet: String) async throws -> [Float]

        /// Batch embedding. The default runs `embed(snippet:)` serially.
        func embed(snippets: [String]) async throws -> [[Float]]
    }

    extension SemanticEmbeddingProvider {
        var providerName: String { "embedding" }

        func embed(snippets: [String]) async throws -> [[Float]] {
            var results: [[Float]] = []
            results.reserveCapacity(snippets.count)
            for snippet in snippets {
                results.append(try await embed(snippet: snippet))
            }
            return results
        }
    }

    // MARK: - SemanticEmbeddingError

    //  The upstream `UnconfiguredSemanticEmbeddingProvider` (and its
    //  `.notConfigured` error) are intentionally NOT lifted: deadwood always
    //  has a working provider — the deterministic one is a total fallback — so
    //  the throwing "unconfigured" placeholder would be dead code the analyzer
    //  itself flags.
    enum SemanticEmbeddingError: Error, Sendable, CustomStringConvertible {
        case modelLoadFailed(underlying: any Error)
        case inferenceFailed(reason: String)

        var description: String {
            switch self {
            case .modelLoadFailed(let underlying):
                "failed to load embedding model: \(underlying.localizedDescription)"
            case .inferenceFailed(let reason):
                "embedding inference failed: \(reason)"
            }
        }
    }
#endif
