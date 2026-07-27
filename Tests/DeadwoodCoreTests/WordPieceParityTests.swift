//  WordPieceParityTests.swift
//  deadwood
//
//  Pins the hand-rolled `WordPieceTokenizer` against HuggingFace's
//  `swift-transformers`, token id for token id, over real Swift source.
//
//  This is the evidence that dropping the `swift-transformers` dependency is
//  safe: a tokenizer that disagrees with the one the model was trained with
//  produces silently wrong embeddings — wrong ids, wrong vectors, plausible
//  output, no error. Parity is therefore asserted on a corpus (deadwood's own
//  sources), not on a couple of hand-picked strings.
//
//  The differential half of this file is temporary by design: it runs only
//  while `swift-transformers` is still linked (`canImport(Tokenizers)`), so it
//  compiles away the moment the dependency is removed, leaving the golden
//  vectors below as the permanent regression pin.

// Gated with the tokenizer it exercises, which is canImport(CoreML)-only.
#if canImport(CoreML)
    import Foundation
    import Testing

    @testable import DeadwoodCore

    #if canImport(Tokenizers)
        import Tokenizers
    #endif

    @Suite struct WordPieceParityTests {
        static let bundle = "/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Models/MiniLM"
        static var bundleAvailable: Bool { FileManager.default.fileExists(atPath: bundle) }

        /// Snippets chosen to exercise the parts of BERT normalization that Swift
        /// source actually hits: camelCase, punctuation-dense generics and operators,
        /// string literals, comments, accents/emoji, and long identifiers.
        static let probes: [String] = [
            "func handleTap() { self.delegate?.didTap(self) }",
            "let x: [String: any Sendable] = [:]",
            "guard let self else { return }   // early-exit",
            "cancellable = publisher.sink { [weak self] value in self?.apply(value) }",
            "aVeryLongCamelCaseIdentifierThatWordPieceMustSplitIntoManySubwords",
            "/// Résumé naïve café — accented comment with em-dash",
            "let emoji = \"🎉 done\" // trailing",
            "if a<=b && c>=d || e!=f { x += 1 }",
            "@MainActor final class ViewModel: ObservableObject {}",
            "try await withThrowingTaskGroup(of: Void.self) { group in }",
            "",
            "     ",
            "\t\nmixed\r\nwhitespace\t",
            "snake_case_and_UPPER_CASE_MIXED",
            "0x1F_ffff + 1_000_000 * 3.14e-2",
        ]

        static func corpusSnippets(limit: Int) -> [String] {
            let root = "/Users/gc/Developer/ongoing/swift/deadwood/Sources"
            var paths: [String] = []
            if let e = FileManager.default.enumerator(atPath: root) {
                for case let p as String in e where p.hasSuffix(".swift") {
                    paths.append(root + "/" + p)
                }
            }
            var out: [String] = []
            for path in paths.sorted() {
                guard let src = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
                else { continue }
                // Both shapes that reach the tokenizer in production: a single
                // flagged-site line, and the multi-line code window that the
                // embedding path actually feeds it.
                let lines = src.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    out.append(line)
                    if out.count >= limit { return out }
                }
                for start in stride(from: 0, to: lines.count, by: 12) {
                    let window = lines[start..<min(start + 12, lines.count)].joined(separator: "\n")
                    if !window.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        out.append(window)
                        if out.count >= limit { return out }
                    }
                }
            }
            return out
        }

        @Test(
            "Vocabulary loads with BERT's canonical special-token ids",
            .enabled(if: WordPieceParityTests.bundleAvailable))
        func vocabularyLoads() throws {
            let tokenizer = try WordPieceTokenizer(bundleDir: URL(fileURLWithPath: Self.bundle))
            // [CLS] … [SEP] wrapping, per the model's TemplateProcessing config.
            let ids = tokenizer.encode(text: "hello world")
            #expect(ids.first == 101, "[CLS] must open every sequence")
            #expect(ids.last == 102, "[SEP] must close every sequence")
            #expect(ids.count > 2, "content tokens expected between the specials")
        }

        @Test(
            "Known BERT tokenizations are reproduced exactly",
            .enabled(if: WordPieceParityTests.bundleAvailable))
        func goldenVectors() throws {
            let tokenizer = try WordPieceTokenizer(bundleDir: URL(fileURLWithPath: Self.bundle))
            // bert-base-uncased is a fixed, published vocabulary, so these ids are
            // stable ground truth independent of any library.
            #expect(tokenizer.encode(text: "hello world") == [101, 7592, 2088, 102])
            // Punctuation splits into its own tokens; unknown-ish camel case splits
            // into `##` continuations rather than degrading to [UNK].
            let dotted = tokenizer.encode(text: "self.delegate")
            #expect(dotted.contains(1012), "the '.' must be its own token (id 1012)")
            #expect(!dotted.contains(100), "no [UNK] expected for ordinary identifiers")
        }

        #if canImport(Tokenizers)
            @Test(
                "DIFFERENTIAL: matches swift-transformers token-for-token on the deadwood corpus",
                .enabled(if: WordPieceParityTests.bundleAvailable))
            func matchesSwiftTransformers() async throws {
                let mine = try WordPieceTokenizer(bundleDir: URL(fileURLWithPath: Self.bundle))
                let reference = try await AutoTokenizer.from(
                    modelFolder: URL(fileURLWithPath: Self.bundle))

                var checked = 0
                var mismatches: [(String, [Int], [Int])] = []
                for snippet in Self.probes + Self.corpusSnippets(limit: 12000) {
                    let a = mine.encode(text: snippet)
                    let b = reference.encode(text: snippet)
                    checked += 1
                    if a != b, mismatches.count < 5 {
                        mismatches.append((snippet, a, b))
                    }
                }
                if !mismatches.isEmpty {
                    for (snippet, a, b) in mismatches {
                        print("MISMATCH on: \(snippet.prefix(90))\n  mine: \(a.prefix(24))\n  ref : \(b.prefix(24))")
                    }
                }
                #expect(mismatches.isEmpty, "\(mismatches.count) mismatching snippet(s) of \(checked)")
                print("WordPiece parity: \(checked) snippets identical to swift-transformers")
            }
        #endif
    }
#endif
