//  BundleTokenizer.swift
//  deadwood
//
//  Picks the tokenizer a model bundle actually declares, so `--embedding-bundle`
//  accepts both families that matter for code embeddings:
//
//  - **WordPiece** (BERT-family) — all-MiniLM-L6-v2, BGE, MS-MARCO.
//  - **byte-level BPE** (GPT-2 / RoBERTa family) — CodeBERT, GraphCodeBERT.
//
//  Selection reads `tokenizer.json`'s `model.type` rather than guessing from
//  file names, and a bundle whose tokenizer is neither (SentencePiece/Unigram)
//  fails to load — deliberately, because the caller then falls back to a
//  working provider. Tokenizing with the wrong scheme would not error; it would
//  silently produce meaningless vectors.

import Foundation

/// The tokenization surface the Core ML provider needs: text in, model token
/// ids out (special tokens included).
protocol SubwordTokenizing: Sendable {
    func encode(text: String) -> [Int]
}

extension WordPieceTokenizer: SubwordTokenizing {}
extension BPETokenizer: SubwordTokenizing {}

enum BundleTokenizer {
    enum SelectionError: Error, LocalizedError {
        case unsupportedTokenizer(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedTokenizer(let kind):
                """
                Unsupported tokenizer '\(kind)': deadwood implements WordPiece \
                (BERT-family, e.g. all-MiniLM-L6-v2) and byte-level BPE \
                (RoBERTa-family, e.g. CodeBERT). Use a bundle from either family.
                """
            }
        }
    }

    /// Builds the tokenizer `bundleDir` declares.
    ///
    /// `tokenizer.json`'s `model.type` is authoritative. Bundles that ship only
    /// the classic BERT `vocab.txt` (no `tokenizer.json`) are treated as
    /// WordPiece, which is what that layout has always meant.
    static func make(bundleDir: URL) throws -> any SubwordTokenizing {
        let root: [String: Any]? =
            (try? Data(contentsOf: bundleDir.appendingPathComponent("tokenizer.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? nil
        let declared = (root?["model"] as? [String: Any])?["type"] as? String

        switch declared {
        case "BPE":
            return try BPETokenizer(bundleDir: bundleDir)
        case "WordPiece":
            return try WordPieceTokenizer(bundleDir: bundleDir)
        case .some(let other):
            throw SelectionError.unsupportedTokenizer(other)
        case nil:
            // No tokenizer.json: only the bare-vocab.txt WordPiece layout is
            // unambiguous, and its own loader reports a missing vocabulary.
            return try WordPieceTokenizer(bundleDir: bundleDir)
        }
    }
}
