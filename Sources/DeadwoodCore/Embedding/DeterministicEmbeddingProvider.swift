//  Lifted from SwiftStaticAnalysis (MIT) —
//  DuplicationDetector/Semantic/DeterministicEmbeddingProvider.swift.
//  Unchanged apart from being `internal` and sharing the Embedding gate. This
//  is the reliable default for CI/smoke and the fallback when the NL
//  contextual asset is unavailable — it needs no model and never fails.

#if canImport(NaturalLanguage)
    import Foundation

    // MARK: - DeterministicEmbeddingProvider

    /// A deterministic, dependency-free embedding provider. Produces a stable
    /// `[Float]` vector by hashing character n-grams into bucketed counts. NOT
    /// semantically meaningful — code that differs only by renamed identifiers
    /// hashes to distinct buckets — but it is total (never throws) and stable,
    /// so it is the smoke/CI default and the fallback when the NL contextual
    /// asset is missing.
    struct DeterministicEmbeddingProvider: SemanticEmbeddingProvider {
        let embeddingDimension: Int
        let ngramSize: Int

        init(dimension: Int = 128, ngramSize: Int = 3) {
            precondition(dimension > 0, "dimension must be > 0")
            precondition(ngramSize > 0, "ngramSize must be > 0")
            self.embeddingDimension = dimension
            self.ngramSize = ngramSize
        }

        func embed(snippet: String) async throws -> [Float] {
            var buckets = [Float](repeating: 0, count: embeddingDimension)
            let chars = Array(snippet.unicodeScalars)
            guard chars.count >= ngramSize else { return buckets }

            for i in 0...(chars.count - ngramSize) {
                var hash: UInt64 = 0xCBF2_9CE4_8422_2325  // FNV-1a offset basis
                for j in 0..<ngramSize {
                    hash ^= UInt64(chars[i + j].value)
                    hash = hash &* 0x0000_0100_0000_01B3  // FNV-1a prime
                }
                let bucket = Int(hash % UInt64(embeddingDimension))
                buckets[bucket] += 1
            }
            return buckets
        }
    }
#endif
