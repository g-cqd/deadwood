//  BPETokenizer.swift
//  deadwood
//
//  Byte-level BPE (the GPT-2 / RoBERTa family), the second half of the
//  dependency-free tokenizer pair — see ``WordPieceTokenizer`` for why these
//  are hand-rolled rather than pulled from `swift-transformers`.
//
//  This is what unlocks the *code-trained* bundles: CodeBERT and GraphCodeBERT
//  are RoBERTa derivatives, so they tokenize with byte-level BPE rather than
//  WordPiece. Fidelity is pinned the same way — `BPEParityTests` diffs this
//  against `swift-transformers` token-for-token over a real corpus using the
//  actual CodeBERT vocabulary.
//
//  The pipeline, matching what the model's `tokenizer.json` declares:
//
//  1. **Pre-tokenize** with GPT-2's regex, which keeps a leading space attached
//     to the following word (` self` is one pre-token, not `` + `self`) — this
//     is why BPE vocabularies are full of `Ġ`-prefixed entries.
//  2. **Byte-map**: take each pre-token's UTF-8 bytes through GPT-2's
//     bytes-to-unicode table, so every possible byte becomes one printable
//     scalar. Byte-level BPE therefore never needs `[UNK]`: any input, valid
//     UTF-8 or not, is representable.
//  3. **Merge**: repeatedly apply the highest-priority (lowest-rank) adjacent
//     pair from `merges`, all occurrences per pass, exactly as GPT-2's `bpe()`.
//  4. **Wrap** as `<s> … </s>` per the `RobertaProcessing` post-processor.

import Foundation

/// Byte-level BPE tokenization over a model bundle's `vocab.json` + `merges`.
struct BPETokenizer: Sendable {
    enum TokenizerError: Error, LocalizedError {
        case noVocabulary(String)
        case noMerges(String)

        var errorDescription: String? {
            switch self {
            case .noVocabulary(let path):
                "No vocab.json (or tokenizer.json vocabulary) found in \(path)"
            case .noMerges(let path):
                "No merges.txt (or tokenizer.json merges) found in \(path)"
            }
        }
    }

    private let vocabulary: [String: Int]
    /// Merge priority: lower rank wins. Keyed by the joined pair to avoid
    /// hashing a tuple on every lookup in the inner loop.
    private let mergeRanks: [String: Int]
    private let unknownID: Int?
    private let prefixID: Int?
    private let suffixID: Int?
    private let addedTokensByLengthDescending: [(String, Int)]

    /// GPT-2's reversible byte-to-scalar table: 256 distinct printable scalars,
    /// so a byte sequence survives a round trip through a text vocabulary.
    private static let byteEncoder: [Character] = {
        var bytes: [UInt32] = []
        bytes.append(contentsOf: UInt32(UInt8(ascii: "!"))...UInt32(UInt8(ascii: "~")))
        bytes.append(contentsOf: UInt32(0xA1)...UInt32(0xAC))
        bytes.append(contentsOf: UInt32(0xAE)...UInt32(0xFF))
        var mapped = bytes
        var next: UInt32 = 0
        for byte in UInt32(0)...UInt32(255) where !bytes.contains(byte) {
            bytes.append(byte)
            mapped.append(256 + next)
            next += 1
        }
        var table = [Character](repeating: " ", count: 256)
        for (byte, scalarValue) in zip(bytes, mapped) {
            if let scalar = Unicode.Scalar(scalarValue) {
                table[Int(byte)] = Character(scalar)
            }
        }
        return table
    }()

    /// GPT-2's pre-tokenization pattern, verbatim from the `ByteLevel`
    /// pre-tokenizer (`use_regex: true`). Contractions first, then
    /// space-prefixed letter / number / symbol runs, then whitespace.
    private static let pattern =
        "'s|'t|'re|'ve|'m|'ll|'d| ?\\p{L}+| ?\\p{N}+| ?[^\\s\\p{L}\\p{N}]+|\\s+(?!\\S)|\\s+"
    private static let regex: NSRegularExpression? = try? NSRegularExpression(pattern: pattern)

    init(bundleDir: URL) throws {
        let root: [String: Any]? =
            (try? Data(contentsOf: bundleDir.appendingPathComponent("tokenizer.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? nil
        let model = root?["model"] as? [String: Any]

        // Vocabulary: tokenizer.json first, then the standalone vocab.json.
        var table = model?["vocab"] as? [String: Int] ?? [:]
        if table.isEmpty,
            let data = try? Data(contentsOf: bundleDir.appendingPathComponent("vocab.json")),
            let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Int]
        {
            table = parsed
        }
        guard !table.isEmpty else { throw TokenizerError.noVocabulary(bundleDir.path) }

        // Merges: tokenizer.json carries them as ["a", "b"] pairs (newer
        // exports) or "a b" strings (older ones); merges.txt is the fallback,
        // where the first line is a `#version:` banner.
        var ranks: [String: Int] = [:]
        if let merges = model?["merges"] as? [Any] {
            for (rank, entry) in merges.enumerated() {
                if let pair = entry as? [String], pair.count == 2 {
                    ranks[pair[0] + "\u{0}" + pair[1]] = rank
                } else if let line = entry as? String {
                    let parts = line.split(separator: " ")
                    if parts.count == 2 { ranks[parts[0] + "\u{0}" + parts[1]] = rank }
                }
            }
        }
        if ranks.isEmpty,
            let text = try? String(
                contentsOf: bundleDir.appendingPathComponent("merges.txt"), encoding: .utf8)
        {
            var rank = 0
            for line in text.split(separator: "\n") {
                if line.hasPrefix("#") { continue }
                let parts = line.split(separator: " ")
                if parts.count == 2 {
                    ranks[parts[0] + "\u{0}" + parts[1]] = rank
                    rank += 1
                }
            }
        }
        guard !ranks.isEmpty else { throw TokenizerError.noMerges(bundleDir.path) }

        var added: [String: Int] = [:]
        for entry in (root?["added_tokens"] as? [[String: Any]]) ?? [] {
            if let content = entry["content"] as? String, let id = entry["id"] as? Int {
                added[content] = id
            }
        }

        self.vocabulary = table
        self.mergeRanks = ranks
        self.unknownID = table["<unk>"]
        self.prefixID = table["<s>"]
        self.suffixID = table["</s>"]
        self.addedTokensByLengthDescending =
            added
            .sorted { ($0.key.count, $0.key) > ($1.key.count, $1.key) }
            .map { ($0.key, $0.value) }
    }

    /// Token ids for `text`, wrapped as `<s> … </s>`.
    func encode(text: String) -> [Int] {
        var ids: [Int] = []
        if let prefixID { ids.append(prefixID) }
        for segment in splitOnAddedTokens(text) {
            switch segment {
            case .added(let id):
                ids.append(id)
            case .text(let run):
                for preToken in Self.preTokenize(run) {
                    for piece in merge(Self.byteMap(preToken)) {
                        if let id = vocabulary[piece] {
                            ids.append(id)
                        } else if let unknownID {
                            ids.append(unknownID)
                        }
                    }
                }
            }
        }
        if let suffixID { ids.append(suffixID) }
        return ids
    }

    // MARK: - Added tokens

    private enum Segment {
        case added(Int)
        case text(String)
    }

    private func splitOnAddedTokens(_ text: String) -> [Segment] {
        guard !addedTokensByLengthDescending.isEmpty else { return [.text(text)] }
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

    // MARK: - ByteLevel pre-tokenization

    private static func preTokenize(_ text: String) -> [String] {
        guard let regex else { return [text] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        // No match at all (empty input) yields no pre-tokens, which is correct:
        // the sequence is then just `<s></s>`.
        return matches.map { ns.substring(with: $0.range) }
    }

    /// Each pre-token's UTF-8 bytes through GPT-2's byte table — the step that
    /// turns a leading space into `Ġ` and makes every byte representable.
    private static func byteMap(_ preToken: String) -> String {
        var out = String()
        out.reserveCapacity(preToken.utf8.count)
        for byte in preToken.utf8 { out.append(byteEncoder[Int(byte)]) }
        return out
    }

    // MARK: - BPE

    /// GPT-2's `bpe()`: find the adjacent pair with the lowest merge rank,
    /// merge every occurrence of it, repeat until no pair is mergeable.
    private func merge(_ word: String) -> [String] {
        var symbols = word.map(String.init)
        guard symbols.count > 1 else { return symbols }

        while true {
            var bestRank = Int.max
            var bestIndex = -1
            for i in 0..<(symbols.count - 1) {
                if let rank = mergeRanks[symbols[i] + "\u{0}" + symbols[i + 1]], rank < bestRank {
                    bestRank = rank
                    bestIndex = i
                }
            }
            guard bestIndex >= 0 else { break }

            let first = symbols[bestIndex]
            let second = symbols[bestIndex + 1]
            var merged: [String] = []
            merged.reserveCapacity(symbols.count)
            var i = 0
            while i < symbols.count {
                if i < symbols.count - 1, symbols[i] == first, symbols[i + 1] == second {
                    merged.append(first + second)
                    i += 2
                } else {
                    merged.append(symbols[i])
                    i += 1
                }
            }
            symbols = merged
            if symbols.count == 1 { break }
        }
        return symbols
    }
}
