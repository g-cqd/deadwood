//  Tests for the opt-in Core ML / HuggingFace embedding bundle: the selection's
//  fall-through and one real load of a local MiniLM bundle. The auto-discovery
//  search is analyzerkit's (`EmbeddingBundleLocator`, tested there).

#if canImport(CoreML)
    import Foundation
    import SemanticEmbedding
    import Testing

    @testable import DeadwoodCore

    // MARK: - Bundle load (local-only; models are gitignored)

    @Suite struct EmbeddingBundleLoadTests {
        /// A code-trained MiniLM Core ML + tokenizer bundle, present only on the
        /// author's machine. Absent in CI → these tests skip.
        static let miniLMBundle = "/Users/me/Developer/ongoing/swift/SwiftStaticAnalysis/Models/MiniLM"

        static var bundleAvailable: Bool {
            FileManager.default.fileExists(atPath: miniLMBundle)
        }

        @Test(.enabled(if: EmbeddingBundleLoadTests.bundleAvailable))
        func bundleProviderEmbedsAndNamesItself() async throws {
            let provider = try await HFSemanticEmbeddingProvider(
                bundleDir: URL(fileURLWithPath: Self.miniLMBundle),
                maxLength: 128
            )
            #expect(provider.providerName == "bundle:MiniLM")
            #expect(provider.embeddingDimension > 0)

            let vector = try await provider.embed(snippet: "private func unusedHelper() -> Int { 0 }")
            #expect(vector.count == provider.embeddingDimension)
            #expect(vector.contains { $0 != 0 })
        }

        @Test(.enabled(if: EmbeddingBundleLoadTests.bundleAvailable))
        func selectionPrefersAnExplicitBundleAndReportsNoNote() async {
            let (provider, notes) = await EmbeddingProviderSelection.resolve(
                bundlePath: Self.miniLMBundle
            )
            #expect(provider.providerName == "bundle:MiniLM")
            #expect(notes.isEmpty)
        }

        @Test func unloadableBundleFallsThroughWithANote() async throws {
            // A directory holding no model must degrade, never fail the run.
            let empty = FileManager.default.temporaryDirectory
                .appending(path: "dw-empty-bundle-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: empty) }

            let (provider, notes) = await EmbeddingProviderSelection.resolve(bundlePath: empty.path)
            #expect(!provider.providerName.hasPrefix("bundle:"))
            #expect(notes.contains { $0.contains("--embedding-bundle") })
        }

        /// The `analyze(…, embeddingBundle:)` argument must reach the resolver:
        /// a bundle that loads has to show up as the scoring model in both the
        /// stderr note and every annotation, or the flag is silently inert.
        @Test(.enabled(if: EmbeddingBundleLoadTests.bundleAvailable))
        func analyzeScoresThroughTheRequestedBundle() async throws {
            let corpus = try Self.stageUnusedCorpus()
            defer { try? FileManager.default.removeItem(at: corpus.dir) }

            let report = await Analyzer().analyze(
                files: [corpus.file.path],
                embeddingConfidence: true,
                embeddingBundle: Self.miniLMBundle
            )

            #expect(report.notes.contains { $0.contains("via bundle:MiniLM") })
            #expect(report.findings.allSatisfy { $0.note?.contains("bundle:MiniLM") == true })
        }

        /// …and an unloadable one degrades in place: same findings, a note that
        /// says so, and the on-device provider named in the annotations.
        @Test func analyzeWithAnUnloadableBundleKeepsTheFindingSet() async throws {
            let corpus = try Self.stageUnusedCorpus()
            defer { try? FileManager.default.removeItem(at: corpus.dir) }
            let empty = corpus.dir.appending(path: "no-model")
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

            let plain = await Analyzer().analyze(files: [corpus.file.path])
            let degraded = await Analyzer().analyze(
                files: [corpus.file.path],
                embeddingConfidence: true,
                embeddingBundle: empty.path
            )

            #expect(
                plain.findings.map { "\($0.rule.rawValue):\($0.line)" }
                    == degraded.findings.map { "\($0.rule.rawValue):\($0.line)" }
            )
            #expect(degraded.notes.contains { $0.contains("--embedding-bundle") })
            #expect(degraded.findings.allSatisfy { $0.note?.contains("bundle:") != true })
        }

        /// A few unused declarations — enough for the kNN score to have peers.
        private static func stageUnusedCorpus() throws -> (dir: URL, file: URL) {
            let dir = FileManager.default.temporaryDirectory
                .appending(path: "dw-bundle-\(UUID().uuidString)")
            var completed = false
            defer {
                if !completed { try? FileManager.default.removeItem(at: dir) }
            }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appending(path: "Sample.swift")
            try """
            private func unusedOne() {}
            private func unusedTwo() {}
            private struct UnusedThree {}
            public func entry() { print("x") }
            """.write(to: file, atomically: true, encoding: .utf8)
            completed = true
            return (dir, file)
        }

        @Test func noBundlePathResolvesWithoutANote() async {
            // The zero-flag path always yields a working provider (the system NL
            // asset, or the deterministic fallback) and says nothing on stderr.
            let (provider, notes) = await EmbeddingProviderSelection.resolve(bundlePath: nil)
            #expect(notes.isEmpty)
            #expect(provider.embeddingDimension > 0)
        }
    }
#endif
