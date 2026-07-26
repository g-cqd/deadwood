//  Ported from dolly (which lifted it from SwiftStaticAnalysis, MIT) —
//  DollyCore/Semantic/HFSemanticEmbeddingProvider.swift.
//
//  A `SemanticEmbeddingProvider` backed by a Core ML model plus the BERT
//  WordPiece tokenizer it was trained with (`WordPieceTokenizer`, built in
//  rather than pulled from swift-transformers — see that file for why, and
//  `WordPieceParityTests` for the token-for-token pin). This is the `--embedding-bundle`
//  provider: point it at a directory holding both the Core ML model
//  (`.mlpackage` — compiled on first use — or a prebuilt `.mlmodelc`) and the
//  tokenizer files (`vocab.txt` / `tokenizer.json`). It covers the WordPiece
//  feature-extraction shape used by MiniLM, CodeBERT and GraphCodeBERT; BPE and
//  SentencePiece bundles fail to load rather than tokenizing wrongly, and the
//  caller falls back to the zero-download provider.
//
//  Why it exists: the default `NLContextualEmbedding` is an English
//  natural-language model. On code it maps unrelated declarations into one
//  narrow cone of the vector space, so the kNN anomaly spread compresses and
//  the annotation says less. A code-trained bundle keeps the neighbourhoods
//  tight, which is exactly what the outlier score reads.
//
//  Changes during the port: deadwood's two-case `SemanticEmbeddingError`
//  (whose `.modelLoadFailed` renders `localizedDescription`, hence the
//  `LocalizedError` conformance below), deadwood's indentation, and the
//  Core ML input builder kept file-local — dolly factors it into a shared file
//  because it has a second Core ML provider; deadwood has exactly one.

#if canImport(CoreML)
    import CoreML
    import Foundation

    // MARK: - HFSemanticEmbeddingProvider

    /// Embeds snippets with a bundled Core ML transformer, mean-pooling the
    /// model's per-token `last_hidden_state` over the real (non-padding)
    /// tokens.
    ///
    /// `@unchecked Sendable` because `MLModel` and the HF `Tokenizer` are not
    /// annotated: both are used read-only here (one `prediction(from:)` call
    /// per snippet, no mutable provider state), and every stored property is a
    /// `let`, so no shared mutable state crosses an isolation boundary.
    final class HFSemanticEmbeddingProvider: SemanticEmbeddingProvider, @unchecked Sendable {
        let embeddingDimension: Int
        let providerName: String

        /// - Parameters:
        ///   - bundleDir: directory holding both the Core ML bundle and the HF
        ///     tokenizer folder.
        ///   - modelURL: explicit model-bundle override; when `nil` the
        ///     provider picks the first `.mlpackage` / `.mlmodelc` in
        ///     `bundleDir`.
        ///   - maxLength: cap on post-tokenization sequence length.
        ///   - inputIDsName / attentionMaskName / tokenTypeIDsName /
        ///     positionIDsName: model input feature names (the optional two are
        ///     fed only when the model declares them).
        ///   - lastHiddenStateName: per-token output, mean-pooled here.
        init(
            bundleDir: URL,
            modelURL: URL? = nil,
            maxLength: Int = 256,
            inputIDsName: String = "input_ids",
            attentionMaskName: String = "attention_mask",
            tokenTypeIDsName: String? = "token_type_ids",
            positionIDsName: String? = "position_ids",
            lastHiddenStateName: String = "last_hidden_state"
        ) async throws {
            self.providerName = "bundle:\(bundleDir.lastPathComponent)"
            let resolvedModelURL: URL
            if let modelURL {
                resolvedModelURL = modelURL
            } else if let found = Self.findModel(in: bundleDir) {
                resolvedModelURL = found
            } else {
                throw SemanticEmbeddingError.modelLoadFailed(
                    underlying: HFProviderError.noModel(bundleDir.path))
            }

            let compiledURL: URL
            if resolvedModelURL.pathExtension == "mlmodelc" {
                compiledURL = resolvedModelURL
            } else {
                do {
                    compiledURL = try await MLModel.compileModel(at: resolvedModelURL)
                } catch {
                    throw SemanticEmbeddingError.modelLoadFailed(underlying: error)
                }
            }

            // Deliberately NOT `.all`: these are sequence-length-flexible exports,
            // and a RoBERTa-family model whose output is
            // `hidden_states [batch, sequence, hidden]` is data-dependent, which
            // the Neural Engine runtime refuses. Worse, it refuses at *prediction*
            // time by writing an opaque Espresso "Invalid blob shape" diagnostic
            // straight to **stdout** — corrupting `--format json` for the caller
            // (measured: CodeBERT emitted 19 KB of that garbage ahead of the
            // report). Even probing `.all` first is unsafe, because the probe's
            // own failure prints it. Cost is small and bounded (~0.95 s -> ~1.35 s
            // for a 30-finding rank, mostly model load), and it buys uncorrupted
            // machine-readable output plus RoBERTa-family bundles working at all.
            var loaded: MLModel?
            for units in [MLComputeUnits.cpuAndGPU, .cpuOnly] {
                let configuration = MLModelConfiguration()
                configuration.computeUnits = units
                guard let candidate = try? MLModel(contentsOf: compiledURL, configuration: configuration)
                else { continue }
                if HFSemanticEmbeddingProvider.probeSucceeds(
                    candidate, inputIDsName: inputIDsName, attentionMaskName: attentionMaskName,
                    tokenTypeIDsName: tokenTypeIDsName, positionIDsName: positionIDsName)
                {
                    loaded = candidate
                    break
                }
            }
            guard let resolvedModel = loaded else {
                throw SemanticEmbeddingError.modelLoadFailed(
                    underlying: HFProviderError.noWorkingComputeUnit(compiledURL.lastPathComponent))
            }
            self.model = resolvedModel

            do {
                self.tokenizer = try BundleTokenizer.make(bundleDir: bundleDir)
            } catch {
                throw SemanticEmbeddingError.modelLoadFailed(underlying: error)
            }

            self.maxLength = maxLength
            self.inputIDsName = inputIDsName
            self.attentionMaskName = attentionMaskName
            self.tokenTypeIDsName = tokenTypeIDsName
            self.positionIDsName = positionIDsName

            // Resolve the output name: the requested one, then the common
            // alternates, then the first declared multi-array output.
            let declaredOutputs = model.modelDescription.outputDescriptionsByName
            if declaredOutputs[lastHiddenStateName] != nil {
                self.lastHiddenStateName = lastHiddenStateName
            } else if declaredOutputs["hidden_states"] != nil {
                self.lastHiddenStateName = "hidden_states"
            } else if declaredOutputs["output"] != nil {
                self.lastHiddenStateName = "output"
            } else if let first = declaredOutputs.first(where: { $0.value.type == .multiArray }) {
                self.lastHiddenStateName = first.key
            } else {
                self.lastHiddenStateName = lastHiddenStateName
            }

            // Which optional inputs does this model actually accept?
            let inputDescriptions = model.modelDescription.inputDescriptionsByName
            let declaredInputs = Set(inputDescriptions.keys)
            self.acceptsTokenTypeIDs = tokenTypeIDsName.map(declaredInputs.contains) ?? false
            self.acceptsPositionIDs = positionIDsName.map(declaredInputs.contains) ?? false

            // Fixed input shape? Fully-baked exports declare `input_ids` as
            // e.g. [1, 128]; dynamic exports use [1, 1] or leave it
            // unconstrained.
            if let inputDescription = inputDescriptions[inputIDsName],
                let shape = inputDescription.multiArrayConstraint?.shape,
                shape.count == 2, shape[1].intValue > 1
            {
                self.fixedSequenceLength = shape[1].intValue
            } else {
                self.fixedSequenceLength = nil
            }

            // Embedding dimension: the HF config.json `hidden_size`, else the
            // output shape, else the BERT-base fallback.
            let configURL = bundleDir.appending(path: "config.json")
            if let hiddenSize = Self.readHiddenSize(from: configURL) {
                self.embeddingDimension = hiddenSize
            } else if let outputDescription = declaredOutputs[self.lastHiddenStateName],
                let shape = outputDescription.multiArrayConstraint?.shape,
                shape.count == 3, shape[2].intValue > 0
            {
                self.embeddingDimension = shape[2].intValue
            } else {
                self.embeddingDimension = Self.defaultDimensionGuess
            }
        }

        func embed(snippet: String) async throws -> [Float] {
            // Tokenize with the model's own WordPiece vocabulary (plus its
            // special tokens), capped to the model's fixed length or `maxLength`.
            var ids = tokenizer.encode(text: snippet)
            let effectiveMax = fixedSequenceLength ?? maxLength
            if ids.count > effectiveMax {
                ids = Array(ids.prefix(effectiveMax))
            }
            let realTokenCount = ids.count
            guard realTokenCount > 0 else {
                throw SemanticEmbeddingError.inferenceFailed(
                    reason: "tokenizer produced an empty sequence")
            }
            let sequenceLength = fixedSequenceLength ?? realTokenCount

            // Every Int32 input goes through one builder: the attention mask is
            // 1 for real tokens and 0 for padding; ids pad with 0.
            var features: [String: MLFeatureValue] = [
                inputIDsName: MLFeatureValue(
                    multiArray: try MLInt32Input.make(length: sequenceLength) {
                        $0 < realTokenCount ? Int32(ids[$0]) : 0
                    }),
                attentionMaskName: MLFeatureValue(
                    multiArray: try MLInt32Input.make(length: sequenceLength) {
                        $0 < realTokenCount ? 1 : 0
                    }),
            ]
            if acceptsTokenTypeIDs, let name = tokenTypeIDsName {
                features[name] = MLFeatureValue(
                    multiArray: try MLInt32Input.make(length: sequenceLength) { _ in 0 })
            }
            if acceptsPositionIDs, let name = positionIDsName {
                features[name] = MLFeatureValue(
                    multiArray: try MLInt32Input.make(length: sequenceLength) { Int32($0) })
            }

            let output: any MLFeatureProvider
            do {
                let input = try MLDictionaryFeatureProvider(dictionary: features)
                output = try await model.prediction(from: input)
            } catch {
                throw SemanticEmbeddingError.inferenceFailed(reason: "\(error)")
            }

            guard let lastHidden = output.featureValue(for: lastHiddenStateName)?.multiArrayValue
            else {
                throw SemanticEmbeddingError.inferenceFailed(
                    reason: "model output missing '\(lastHiddenStateName)' multi-array")
            }
            return try pool(
                lastHidden, sequenceLength: sequenceLength, realTokenCount: realTokenCount)
        }

        // MARK: - Private

        private let model: MLModel
        private let tokenizer: any SubwordTokenizing
        private let maxLength: Int
        private let inputIDsName: String
        private let attentionMaskName: String
        private let tokenTypeIDsName: String?
        private let positionIDsName: String?
        private let lastHiddenStateName: String
        private let acceptsTokenTypeIDs: Bool
        private let acceptsPositionIDs: Bool
        private let fixedSequenceLength: Int?
        private static let defaultDimensionGuess = 768

        /// Mean-pool the model output over the real tokens. Accepts a
        /// pre-pooled `(1, D)` output (used as-is) or a per-token `(1, T, D)`
        /// one (averaged over the real tokens, skipping padding). Reads through
        /// `MLMultiArray`'s element subscript rather than its raw pointer, so
        /// the package's strict memory safety is satisfied; `.floatValue`
        /// converts whichever numeric dtype the model emits.
        private func pool(
            _ lastHidden: MLMultiArray, sequenceLength: Int, realTokenCount: Int
        ) throws -> [Float] {
            let shape = lastHidden.shape.map(\.intValue)
            if shape.count == 2, shape[0] == 1, shape[1] > 0 {
                let dimension = shape[1]
                var pooled = [Float](repeating: 0, count: dimension)
                for d in 0..<dimension { pooled[d] = lastHidden[d].floatValue }
                return pooled
            }
            guard shape.count == 3, shape[0] == 1, shape[1] == sequenceLength else {
                throw SemanticEmbeddingError.inferenceFailed(
                    reason:
                        "unexpected \(lastHiddenStateName) shape \(shape) for seqLen=\(sequenceLength)"
                )
            }
            let dimension = shape[2]
            var pooled = [Float](repeating: 0, count: dimension)
            for t in 0..<realTokenCount {
                let base = t * dimension
                for d in 0..<dimension { pooled[d] += lastHidden[base + d].floatValue }
            }
            let scale = 1.0 / Float(realTokenCount)
            for d in 0..<dimension { pooled[d] *= scale }
            return pooled
        }

        /// `.mlpackage` first, then `.mlmodelc`, one level deep in `dir`.
        private static func findModel(in dir: URL) -> URL? {
            guard
                let contents = try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil)
            else { return nil }
            for url in contents where url.pathExtension == "mlpackage" { return url }
            for url in contents where url.pathExtension == "mlmodelc" { return url }
            return nil
        }

        /// Read `hidden_size` (or T5's `d_model`) from a HF `config.json`.
        private static func readHiddenSize(from configURL: URL) -> Int? {
            guard let data = try? Data(contentsOf: configURL),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            if let hidden = json["hidden_size"] as? Int { return hidden }
            if let hidden = json["d_model"] as? Int { return hidden }
            return nil
        }
    }

    // MARK: - MLInt32Input

    /// Builds the `[1, length]` Int32 inputs every HF encoder expects, so the
    /// four near-identical MLMultiArray-filling blocks collapse to one.

    extension HFSemanticEmbeddingProvider {
        /// Runs one tiny prediction to find out whether `model` can actually
        /// execute on the compute units it was loaded with — Core ML defers that
        /// incompatibility to prediction time.
        fileprivate static func probeSucceeds(
            _ model: MLModel,
            inputIDsName: String,
            attentionMaskName: String,
            tokenTypeIDsName: String?,
            positionIDsName: String?
        ) -> Bool {
            let declaredInputs = Set(model.modelDescription.inputDescriptionsByName.keys)
            guard declaredInputs.contains(inputIDsName) else { return false }
            let length = 4
            guard
                let ids = try? MLInt32Input.make(length: length, { _ in 1 }),
                let mask = try? MLInt32Input.make(length: length, { _ in 1 })
            else { return false }
            var features: [String: MLFeatureValue] = [
                inputIDsName: MLFeatureValue(multiArray: ids)
            ]
            if declaredInputs.contains(attentionMaskName) {
                features[attentionMaskName] = MLFeatureValue(multiArray: mask)
            }
            for optional in [tokenTypeIDsName, positionIDsName] {
                guard let name = optional, declaredInputs.contains(name),
                    let zeros = try? MLInt32Input.make(length: length, { _ in 0 })
                else { continue }
                features[name] = MLFeatureValue(multiArray: zeros)
            }
            guard let provider = try? MLDictionaryFeatureProvider(dictionary: features) else {
                return false
            }
            return (try? model.prediction(from: provider)) != nil
        }
    }

    private enum MLInt32Input {
        static func make(length: Int, _ value: (Int) -> Int32) throws -> MLMultiArray {
            let array: MLMultiArray
            do {
                array = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
            } catch {
                throw SemanticEmbeddingError.inferenceFailed(reason: "\(error)")
            }
            for i in 0..<length {
                array[[0, NSNumber(value: i)]] = NSNumber(value: value(i))
            }
            return array
        }
    }

    // MARK: - HFProviderError

    /// Provider-local reasons, wrapped by
    /// `SemanticEmbeddingError.modelLoadFailed`. `LocalizedError` because that
    /// case renders its underlying error's `localizedDescription`, which for a
    /// bare Swift error would otherwise print as an opaque domain/code pair
    /// and lose the path the user needs to fix.
    private enum HFProviderError: LocalizedError, CustomStringConvertible {
        case noModel(String)
        case noWorkingComputeUnit(String)

        var description: String {
            switch self {
            case .noModel(let path): "no .mlpackage or .mlmodelc found in \(path)"
            case .noWorkingComputeUnit(let name):
                """
                \(name) failed a trial prediction on every compute unit (GPU, CPU) — \
                the export is likely incompatible with this Core ML runtime
                """
            }
        }

        var errorDescription: String? { description }
    }
#endif
