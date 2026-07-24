//  Lifted from SwiftStaticAnalysis (MIT) —
//  DuplicationDetector/Semantic/NLContextualSemanticEmbeddingProvider.swift.
//  Changes during the lift: `internal`, and the doc trimmed to deadwood's use.
//  This is the DEFAULT provider for `--experimental-embedding-confidence`:
//  Apple's system `NLContextualEmbedding` (macOS 14+), a system-provided asset
//  with ZERO download of a third-party model. When the asset is unavailable
//  (offline/sandboxed), construction throws and the caller falls back to the
//  deterministic provider.

#if canImport(NaturalLanguage)
    import Foundation
    import NaturalLanguage

    // MARK: - NLContextualSemanticEmbeddingProvider

    /// A `SemanticEmbeddingProvider` backed by Apple's `NLContextualEmbedding`
    /// (macOS 14+). Token vectors are mean-pooled to one fixed-dimension vector
    /// per snippet. Captures English-language contextual semantics over the
    /// snippet's identifier / comment / keyword stream — enough to place a
    /// declaration as a semantic outlier among its peers.
    @available(macOS 14.0, *)
    struct NLContextualSemanticEmbeddingProvider: SemanticEmbeddingProvider {
        let embeddingDimension: Int
        let language: NLLanguage

        /// Loads the contextual-embedding asset eagerly so a later
        /// `embed(snippet:)` failure surfaces here at construction time.
        init(language: NLLanguage = .english) throws {
            guard let probe = NLContextualEmbedding(language: language) else {
                throw SemanticEmbeddingError.modelLoadFailed(
                    underlying: NLContextualEmbeddingError.unsupportedLanguage(language))
            }
            if !probe.hasAvailableAssets {
                throw SemanticEmbeddingError.modelLoadFailed(
                    underlying: NLContextualEmbeddingError.assetsUnavailable)
            }
            do {
                try probe.load()
            } catch {
                throw SemanticEmbeddingError.modelLoadFailed(underlying: error)
            }
            self.embeddingDimension = probe.dimension
            self.language = language
        }

        func embed(snippet: String) async throws -> [Float] {
            guard let embedding = NLContextualEmbedding(language: language) else {
                throw SemanticEmbeddingError.modelLoadFailed(
                    underlying: NLContextualEmbeddingError.unsupportedLanguage(language))
            }
            do {
                try embedding.load()
            } catch {
                throw SemanticEmbeddingError.modelLoadFailed(underlying: error)
            }

            let result: NLContextualEmbeddingResult
            do {
                result = try embedding.embeddingResult(for: snippet, language: language)
            } catch {
                throw SemanticEmbeddingError.inferenceFailed(reason: error.localizedDescription)
            }

            let dimension = embedding.dimension
            var pooled = [Float](repeating: 0, count: dimension)
            var tokenCount = 0
            result.enumerateTokenVectors(in: snippet.startIndex..<snippet.endIndex) { vector, _ in
                guard vector.count == dimension else { return true }
                for i in 0..<dimension {
                    pooled[i] += Float(vector[i])
                }
                tokenCount += 1
                return true
            }

            if tokenCount > 0 {
                let scale = 1.0 / Float(tokenCount)
                for i in 0..<dimension {
                    pooled[i] *= scale
                }
            }
            return pooled
        }
    }

    // MARK: - NLContextualEmbeddingError

    /// Provider-local error reasons, wrapped by
    /// `SemanticEmbeddingError.modelLoadFailed`.
    enum NLContextualEmbeddingError: Error, CustomStringConvertible {
        case unsupportedLanguage(NLLanguage)
        case assetsUnavailable

        var description: String {
            switch self {
            case .unsupportedLanguage(let language):
                "NLContextualEmbedding does not support language: \(language.rawValue)"
            case .assetsUnavailable:
                "NLContextualEmbedding model assets are not available locally"
            }
        }
    }
#endif
