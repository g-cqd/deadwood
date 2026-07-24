//  New in deadwood (experimental): the embedding-confidence signal wiring.
//  The math is lifted from SwiftStaticAnalysis's `swa anomaly` subcommand:
//  L2-normalize each candidate's embedding, then score it by 1 − (mean cosine
//  to its k nearest neighbours). A declaration whose snippet is a semantic
//  OUTLIER among the other unused candidates gets a high anomaly score — a
//  soft hint that it is more likely genuinely dead. It ONLY annotates the
//  finding note; it never changes which findings fire.

#if canImport(NaturalLanguage)
    import Foundation

    // MARK: - EmbeddingConfidence

    struct EmbeddingConfidence: Sendable {
        /// k for the kNN outlier score.
        let neighbors: Int

        init(neighbors: Int = 5) {
            self.neighbors = neighbors
        }

        /// Anomaly score in `0...1` per snippet index (higher = more of an
        /// outlier). Empty when there are too few snippets or the provider
        /// fails — the caller then simply omits the annotation.
        func anomalyScores(
            snippets: [String],
            provider: any SemanticEmbeddingProvider
        ) async -> [Int: Double] {
            guard snippets.count > 1 else { return [:] }

            let vectors: [[Float]]
            do {
                vectors = try await provider.embed(snippets: snippets)
            } catch {
                return [:]
            }
            let normalized = vectors.map(SearchMath.l2Normalized)
            let k = min(neighbors, snippets.count - 1)

            var scores: [Int: Double] = [:]
            for i in snippets.indices {
                var sims: [Float] = []
                sims.reserveCapacity(snippets.count - 1)
                for j in snippets.indices where i != j {
                    sims.append(SearchMath.cosine(normalized[i], normalized[j]))
                }
                sims.sort(by: >)
                let top = sims.prefix(k)
                guard !top.isEmpty else { continue }
                let mean = top.reduce(Float(0), +) / Float(top.count)
                scores[i] = Double(max(0, min(1, 1 - mean)))
            }
            return scores
        }
    }

    // MARK: - SearchMath

    /// L2-normalization + cosine helpers (lifted from `swa`'s embedding math).
    enum SearchMath {
        static func l2Normalized(_ vector: [Float]) -> [Float] {
            var sumSq: Float = 0
            for value in vector { sumSq += value * value }
            guard sumSq > 0 else { return vector }
            let inverse = 1.0 / sumSq.squareRoot()
            return vector.map { $0 * inverse }
        }

        static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float {
            var accumulator: Float = 0
            let count = min(lhs.count, rhs.count)
            for i in 0..<count { accumulator += lhs[i] * rhs[i] }
            return accumulator
        }
    }
#endif
