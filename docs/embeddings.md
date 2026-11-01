# Scoring findings by similarity (experimental)

`--experimental-embeddings confidence` (macOS) adds a semantic-anomaly score to each finding's note. It embeds every flagged
declaration and scores it as a nearest-neighbour outlier among the others. It annotates only: it never changes which findings
appear or the exit code. The score and the model show in the note and the summary:

```text
embedding-confidence: 41% anomaly [experimental, bundle:MiniLM]
```

By default it uses Apple's on-device `NLContextualEmbedding`, with a deterministic n-gram fallback when the system asset is missing.
It reads English prose, not code, so scores bunch together and discriminate little. A sentence-embedding bundle does better:

```sh
deadwood analyze --experimental-embeddings confidence --embedding-bundle ~/Models/MiniLM Sources
```

A bundle is a directory with a Core ML model (`.mlpackage`, compiled on first use, or `.mlmodelc`) and its WordPiece vocabulary
(`vocab.txt`, or the one in `tokenizer.json`), such as all-MiniLM-L6-v2. Snippets are cut to 128 tokens. BPE and SentencePiece
bundles are not supported and fall back to the default provider.

Choose a **sentence-embedding** model, not a masked-language-model checkpoint. Masked-LM vectors crowd into one cone and the
scores collapse: on the same 29 findings MiniLM spread scores over 36–77%, Apple's model over 2–8%, and CodeBERT over 1–3%.

With no flag, deadwood looks for `<exec-dir>/Models/MiniLM`, then `<exec-dir>/../share/deadwood/Models/MiniLM`.
`DEADWOOD_EMBEDDING_BUNDLE` overrides both. A bundle that will not load falls back to the on-device provider with a note, and
where CoreML or NaturalLanguage are missing the flag reports itself unavailable.
