//  WordPieceTokenizer.swift
//  deadwood
//
//  A self-contained BERT WordPiece tokenizer — the only piece of HuggingFace's
//  `swift-transformers` this tool ever needed.
//
//  Why hand-rolled: the bundle provider used exactly one call from that package
//  (`AutoTokenizer.from(modelFolder:).encode(text:)`), and paying for it meant
//  linking Tokenizers -> Hub -> Jinja/HuggingFace/Crypto/NIO/ASN1/EventSource/
//  yyjson into every deadwood binary: +9.9 MiB (+41.6%) and ~+100 s of clean build,
//  unconditionally, for an opt-in experimental flag — in a tool whose stated
//  architecture is swift-syntax + swift-argument-parser and nothing else.
//  A BERT-family bundle (MiniLM here) needs WordPiece over a plain `vocab.txt`
//  that already ships inside the bundle, which is this file.
//
//  Fidelity is not assumed, it is pinned: `WordPieceParityTests` compares this
//  implementation against `swift-transformers` token-for-token over the real
//  arcleak corpus, so the substitution is verified rather than hoped for.
//
//  Implements the three stages HuggingFace's `tokenizer.json` declares for this
//  model — `BertNormalizer` (clean_text / handle_chinese_chars / strip_accents /
//  lowercase), `BertPreTokenizer` (whitespace + punctuation splitting), and
//  `WordPiece` (greedy longest-match-first, `##` continuation, `[UNK]` on
//  failure) — then wraps the result as `[CLS] … [SEP]` per the model's
//  `TemplateProcessing` post-processor.

// Gated with the Core ML provider it exists to feed: WordPiece needs NFD
// normalization and JSON vocabulary parsing, neither of which
// FoundationEssentials offers, and it never runs off macOS anyway.
#if canImport(CoreML)
    import Foundation

    /// BERT WordPiece tokenization over a model bundle's `vocab.txt`.
    ///
    /// Cross-platform on purpose (no CoreML gate): the tokenizer is pure Swift, so
    /// its parity tests run on Linux too even though its only consumer — the Core
    /// ML bundle provider — is macOS-only.
    struct WordPieceTokenizer: Sendable {
        enum TokenizerError: Error, LocalizedError {
            case noVocabulary(String)
            case missingSpecialToken(String)

            var errorDescription: String? {
                switch self {
                case .noVocabulary(let path):
                    "No vocab.txt (or tokenizer.json vocabulary) found in \(path)"
                case .missingSpecialToken(let token):
                    "Vocabulary is missing the required special token \(token)"
                }
            }
        }

        private let vocabulary: [String: Int]
        private let unknownID: Int
        private let classifierID: Int
        private let separatorID: Int
        private let continuingPrefix: String
        private let maximumCharactersPerWord: Int
        private let lowercase: Bool
        /// Literals matched atomically ahead of normalization (see `splitOnAddedTokens`).
        private let addedTokens: [String: Int]
        /// The same table, longest literal first, so matching can't mis-segment on
        /// a shorter literal that prefixes a longer one.
        private let addedTokensByLengthDescending: [(String, Int)]

        /// Loads the vocabulary from `bundleDir`. Prefers `vocab.txt` (line index is
        /// the token id — the BERT convention); falls back to the `model.vocab`
        /// object inside `tokenizer.json` for bundles that ship only the JSON.
        init(
            bundleDir: URL,
            continuingPrefix: String = "##",
            maximumCharactersPerWord: Int = 100,
            lowercase: Bool = true
        ) throws {
            var table: [String: Int] = [:]
            let vocabURL = bundleDir.appendingPathComponent("vocab.txt")
            if let text = try? String(contentsOf: vocabURL, encoding: .utf8) {
                // `omittingEmptySubsequences: false` keeps the line index aligned
                // with the token id; only a trailing newline's empty tail is dropped.
                var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                if lines.last?.isEmpty == true { lines.removeLast() }
                for (id, line) in lines.enumerated() {
                    let token = line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
                    if table[token] == nil { table[token] = id }
                }
            }
            // `tokenizer.json` is the source of both the fallback vocabulary and the
            // added-token literals; read it once.
            let jsonURL = bundleDir.appendingPathComponent("tokenizer.json")
            let root: [String: Any]? =
                (try? Data(contentsOf: jsonURL)).flatMap {
                    try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
                } ?? nil

            if table.isEmpty,
                let model = root?["model"] as? [String: Any],
                let vocab = model["vocab"] as? [String: Int]
            {
                table = vocab
            }
            guard !table.isEmpty else { throw TokenizerError.noVocabulary(bundleDir.path) }

            var added: [String: Int] = [:]
            for entry in (root?["added_tokens"] as? [[String: Any]]) ?? [] {
                if let content = entry["content"] as? String, let id = entry["id"] as? Int {
                    added[content] = id
                }
            }
            if added.isEmpty {
                // Bundles without an `added_tokens` list still reserve BERT's five.
                for token in ["[PAD]", "[UNK]", "[CLS]", "[SEP]", "[MASK]"] {
                    if let id = table[token] { added[token] = id }
                }
            }
            self.addedTokens = added
            self.addedTokensByLengthDescending =
                added
                .sorted { ($0.key.count, $0.key) > ($1.key.count, $1.key) }
                .map { ($0.key, $0.value) }

            func require(_ token: String) throws -> Int {
                guard let id = table[token] else { throw TokenizerError.missingSpecialToken(token) }
                return id
            }
            self.vocabulary = table
            self.unknownID = try require("[UNK]")
            self.classifierID = try require("[CLS]")
            self.separatorID = try require("[SEP]")
            self.continuingPrefix = continuingPrefix
            self.maximumCharactersPerWord = maximumCharactersPerWord
            self.lowercase = lowercase
        }

        /// Token ids for `text`, wrapped as `[CLS] … [SEP]`.
        func encode(text: String) -> [Int] {
            var ids: [Int] = [classifierID]
            for segment in splitOnAddedTokens(text) {
                switch segment {
                case .added(let id):
                    ids.append(id)
                case .text(let run):
                    for word in Self.preTokenize(normalize(run)) {
                        ids.append(contentsOf: wordPieces(of: word))
                    }
                }
            }
            ids.append(separatorID)
            return ids
        }

        // MARK: - Added tokens

        private enum Segment {
            case added(Int)
            case text(String)
        }

        /// Added tokens (`[CLS]`, `[SEP]`, `[UNK]`, `[PAD]`, `[MASK]`) are matched
        /// **literally and before normalization**, exactly as HuggingFace does: they
        /// are `normalized: false`, so a source line that mentions `"[UNK]"` encodes
        /// to the single id 100 rather than being split into `[`, `unk`, `##k`, `]`.
        /// Longest-match-first so overlapping literals can't mis-segment.
        private func splitOnAddedTokens(_ text: String) -> [Segment] {
            guard !addedTokens.isEmpty else { return [.text(text)] }
            var segments: [Segment] = []
            var pending = String()
            var index = text.startIndex
            outer: while index < text.endIndex {
                for (literal, id) in addedTokensByLengthDescending
                where text[index...].hasPrefix(literal) {
                    if !pending.isEmpty {
                        segments.append(.text(pending))
                        pending = String()
                    }
                    segments.append(.added(id))
                    index = text.index(index, offsetBy: literal.count)
                    continue outer
                }
                pending.append(text[index])
                index = text.index(after: index)
            }
            if !pending.isEmpty { segments.append(.text(pending)) }
            return segments
        }

        // MARK: - BertNormalizer

        private func normalize(_ text: String) -> String {
            var scalars = String.UnicodeScalarView()
            for scalar in text.unicodeScalars {
                // clean_text: drop NUL and the replacement char, drop control
                // characters, and fold every whitespace form to a plain space.
                if scalar.value == 0 || scalar.value == 0xFFFD { continue }
                if Self.isWhitespace(scalar) {
                    scalars.append(" ")
                    continue
                }
                if Self.isControl(scalar) { continue }
                // handle_chinese_chars: isolate CJK so each ideograph is its own word.
                if Self.isCJK(scalar.value) {
                    scalars.append(" ")
                    scalars.append(scalar)
                    scalars.append(" ")
                    continue
                }
                scalars.append(scalar)
            }

            var result = String(scalars)
            if lowercase {
                // strip_accents is null in this model's config, which HuggingFace
                // resolves to "follow lowercase" — decompose, then drop the
                // combining marks NFD split out.
                result = String(
                    result.decomposedStringWithCanonicalMapping.unicodeScalars.filter {
                        $0.properties.generalCategory != .nonspacingMark
                    })
                result = result.lowercased()
            }
            return result
        }

        // MARK: - BertPreTokenizer

        /// Splits on whitespace, then peels every punctuation scalar into its own
        /// token (so `foo.bar` becomes `foo`, `.`, `bar`).
        private static func preTokenize(_ text: String) -> [String] {
            var words: [String] = []
            var current = String.UnicodeScalarView()
            func flush() {
                if !current.isEmpty {
                    words.append(String(current))
                    current = String.UnicodeScalarView()
                }
            }
            for scalar in text.unicodeScalars {
                if isWhitespace(scalar) {
                    flush()
                } else if isPunctuation(scalar) {
                    flush()
                    words.append(String(scalar))
                } else {
                    current.append(scalar)
                }
            }
            flush()
            return words
        }

        // MARK: - WordPiece

        /// Greedy longest-match-first over `word`. Pieces after the first carry the
        /// continuation prefix; a word that is too long, or that strands at any
        /// position, degrades to a single `[UNK]` (never a partial tokenization).
        private func wordPieces(of word: String) -> [Int] {
            let scalars = Array(word.unicodeScalars)
            guard scalars.count <= maximumCharactersPerWord else { return [unknownID] }
            var pieces: [Int] = []
            var start = 0
            while start < scalars.count {
                var end = scalars.count
                var matched: Int?
                while start < end {
                    var candidate = String(String.UnicodeScalarView(scalars[start..<end]))
                    if start > 0 { candidate = continuingPrefix + candidate }
                    if let id = vocabulary[candidate] {
                        matched = id
                        break
                    }
                    end -= 1
                }
                guard let id = matched else { return [unknownID] }
                pieces.append(id)
                start = end
            }
            return pieces
        }

        // MARK: - Character classes (BERT's definitions, not Swift's)

        private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.value {
            case 0x20, 0x09, 0x0A, 0x0D: true
            default: scalar.properties.generalCategory == .spaceSeparator
            }
        }

        private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
            // Tab/newline/CR are whitespace to BERT, not control characters; they
            // are handled before this is consulted.
            switch scalar.properties.generalCategory {
            case .control, .format, .privateUse, .surrogate: true
            default: false
            }
        }

        private static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
            // BERT treats every non-alphanumeric ASCII glyph as punctuation, which
            // is wider than Unicode's P* categories (it includes `$ + < = > ^ | ~`).
            switch scalar.value {
            case 33...47, 58...64, 91...96, 123...126: return true
            default: break
            }
            switch scalar.properties.generalCategory {
            case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
                .initialPunctuation, .finalPunctuation, .otherPunctuation:
                return true
            default:
                return false
            }
        }

        private static func isCJK(_ value: UInt32) -> Bool {
            switch value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0x2A700...0x2B73F,
                0x2B740...0x2B81F, 0x2B820...0x2CEAF, 0xF900...0xFAFF, 0x2F800...0x2FA1F:
                true
            default:
                false
            }
        }
    }
#endif
