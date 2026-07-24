//  Tests for the experimental embedding-confidence signal. Gated behind the
//  NaturalLanguage gate the substrate uses. The deterministic provider makes
//  the anomaly math testable without any model asset.

#if canImport(NaturalLanguage)
    import Foundation
    import Testing

    @testable import DeadwoodCore

    @Suite struct EmbeddingConfidenceTests {
        @Test func deterministicProviderIsStableAndSized() async throws {
            let provider = DeterministicEmbeddingProvider(dimension: 64)
            let a = try await provider.embed(snippet: "func foo() {}")
            let b = try await provider.embed(snippet: "func foo() {}")
            #expect(a.count == 64)
            #expect(a == b)  // deterministic
        }

        @Test func cosineOfIdenticalVectorsIsOne() {
            let vector = SearchMath.l2Normalized([1, 2, 3, 4])
            #expect(abs(SearchMath.cosine(vector, vector) - 1) < 1e-5)
        }

        @Test func outlierScoresHigherThanTheCluster() async {
            // Three near-identical snippets plus one very different: the outlier
            // must score at least as anomalous as any cluster member.
            let snippets = [
                "func alpha() { return }",
                "func alphb() { return }",
                "func alphc() { return }",
                "class WildlyDifferent { let x = 42; let y = \"totally other\" }",
            ]
            let scores = await EmbeddingConfidence(neighbors: 2).anomalyScores(
                snippets: snippets, provider: DeterministicEmbeddingProvider())
            #expect(scores.count == 4)
            let outlier = scores[3] ?? 0
            let clusterMax = max(scores[0] ?? 0, max(scores[1] ?? 0, scores[2] ?? 0))
            #expect(outlier >= clusterMax)
            for score in scores.values {
                #expect(score >= 0 && score <= 1)
            }
        }

        @Test func tooFewSnippetsYieldNoScores() async {
            let scores = await EmbeddingConfidence().anomalyScores(
                snippets: ["only one"], provider: DeterministicEmbeddingProvider())
            #expect(scores.isEmpty)
        }

        @Test func flagAnnotatesFindingNotesWithoutChangingTheSet() async throws {
            // A fixture with several unused declarations so the kNN score has a
            // pool to work with.
            let dir = FileManager.default.temporaryDirectory
                .appending(path: "dw-emb-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let source = dir.appending(path: "Sample.swift")
            try """
            private func unusedOne() {}
            private func unusedTwo() {}
            private struct UnusedThree {}
            public func entry() { print("x") }
            """.write(to: source, atomically: true, encoding: .utf8)

            let plain = await Analyzer().analyze(files: [source.path])
            let annotated = await Analyzer().analyze(
                files: [source.path], embeddingConfidence: true)

            // The finding SET is unchanged — only notes differ.
            #expect(
                plain.findings.map { "\($0.rule.rawValue):\($0.line)" }
                    == annotated.findings.map { "\($0.rule.rawValue):\($0.line)" })
            #expect(annotated.findings.count > 1)
            #expect(annotated.findings.allSatisfy { $0.note?.contains("embedding-confidence") == true })
            #expect(annotated.notes.contains { $0.contains("embedding-confidence") })
            #expect(plain.notes.isEmpty)
        }
    }
#endif
