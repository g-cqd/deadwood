//  Modeled on arcleak's FactsCache: fail-open per-file cache.

// Fast, reflection-free JSON coders for the cache payload. `AemiJSON.JSONEncoder`/
// `.JSONDecoder` are structs and have no `.outputFormatting` OptionSet.
// AemiJSON is confined to cache payload types, so an internal import suffices.
import AemiJSON

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

// MARK: - CachedFileArtifacts

/// Everything one parse of a file produces (facts, directives, dataflow
/// findings, degraded notes) — exactly what the Analyzer's per-file phase
/// computes, so a cache hit skips the parse and every per-file walk. The
/// corpus-wide graph/BFS and every rule always re-run: findings can never
/// go stale relative to rules or configuration.
struct CachedFileArtifacts: Sendable, Codable {
    let facts: FileAnalysisResult
    let directives: [SuppressionDirective]
    let deadBranches: [UnusedCode]
    let degraded: [String]
}

// MARK: - FactsCache

/// Per-file facts cache. Cache hits skip parsing and per-file extraction;
/// graph construction and detection still run on every analysis.
///
/// The cache is an optimization, so unlike configuration it FAILS OPEN: an
/// unreadable, corrupt, or mismatched cache behaves as empty and is
/// overwritten on persist. Entries are keyed by absolute path and validated
/// by a content fingerprint (FNV-1a 64 over bytes + length — identity, not
/// security; a collision merely serves stale facts for one file until its
/// next real change), salted with configuration. A version or build-identity
/// mismatch discards the whole cache before decoding. The
/// persisted cache is rebuilt from ONLY the current run's files, so absent
/// files are pruned and the cache never grows without bound.
struct FactsCache: Sendable {
    struct Entry: Sendable, Codable {
        let fingerprint: String
        let artifacts: CachedFileArtifacts

        init(fingerprint: String, artifacts: CachedFileArtifacts) {
            self.fingerprint = fingerprint
            self.artifacts = artifacts
        }
    }

    fileprivate struct Payload: Sendable, Codable {
        var tool: String
        var version: String
        var entries: [String: Entry]
    }

    // MARK: - Coder seam

    // The single encode/decode seam. Swapping the JSON coder touches only these
    // two functions; `load` and `persist` both route through them.
    fileprivate static func encodePayload(_ payload: Payload) throws -> Data {
        // AemiJSON's single-pass byte writer over the reflection-free
        // `AemiJSONFastEncodable` graph (`@JSONCodable` structs + `FactsFastCoding`
        // leaves). Default `.rfc8259` options — NO `keyOrder = .sorted`, which
        // would force AemiJSON off the streaming writer into a second
        // compact -> re-parse-tape -> re-emit pass and cripple encode.
        // Determinism (a byte-stable round-trip across decode) instead comes from
        // `Payload.__adjsonEncode` emitting the top-level `entries` map in sorted
        // key order — O(files·log files), not a re-sort of the whole tape. The
        // cache is internal + version-gated, so `2.0`<->`2` and unescaped `/` are
        // harmless: only this tool version ever reads these bytes back.
        let encoder = AemiJSON.JSONEncoder()
        return try encoder.encode(payload)
    }

    fileprivate static func decodePayload(from data: Data) throws -> Payload {
        // Byte-level decode: hand AemiJSON a contiguous `[UInt8]` (no Foundation
        // `Data` bridging in the parser), and the `@JSONCodable`-generated
        // `_FastDecodeCursor` conformances read each field straight off the tape
        // by statically-known key — no `KeyedDecodingContainer`, no per-key String.
        let decoder = AemiJSON.JSONDecoder()
        return try decoder.decode(Payload.self, from: [UInt8](data))
    }

    private(set) var entries: [String: Entry]
    private(set) var loadFailure: String?

    init(entries: [String: Entry] = [:], loadFailure: String? = nil) {
        self.entries = entries
        self.loadFailure = loadFailure
    }

    static func fingerprint(of data: Data, salt: String = "") -> String {
        let prime: UInt64 = 0x0000_0100_0000_01b3
        // FNV-1a over the raw contiguous buffer. `withUnsafeBytes` is the only
        // fast path — `Data`'s element iterator is O(n) with per-byte bridging
        // overhead, and this runs on every file on every run (even cache hits).
        // Invariant: the buffer never escapes the closure; `unsafe` is confined
        // here and covered by the fingerprint stability tests.
        var hash: UInt64 = unsafe data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UInt64 in
            var h: UInt64 = 0xcbf2_9ce4_8422_2325
            let count = raw.count
            var i = 0
            while i < count {
                h ^= UInt64(unsafe raw[i])
                h &*= prime
                i += 1
            }
            return h
        }
        for byte in salt.utf8 {
            hash ^= UInt64(byte)
            hash &*= prime
        }
        return "\(String(hash, radix: 16))-\(data.count)"
    }

    func artifacts(for path: String, fingerprint: String) -> CachedFileArtifacts? {
        guard let entry = entries[path], entry.fingerprint == fingerprint else { return nil }
        return entry.artifacts
    }

    mutating func update(path: String, fingerprint: String, artifacts: CachedFileArtifacts) {
        entries[path] = Entry(fingerprint: fingerprint, artifacts: artifacts)
    }

    /// Fail-open load: any failure — including an over-cap file — returns an
    /// empty cache (the cache is an optimization, never a trust boundary).
    static let maxCacheBytes = 64 * 1024 * 1024

    private static func header(build: String) -> Data {
        Data("deadwood facts 2 \(ToolInfo.version) \(build) json\n".utf8)
    }

    static func load(url: URL, build: String? = BuildIdentity.current) -> FactsCache {
        guard let build, FileManager.default.fileExists(atPath: url.path) else { return FactsCache() }
        let data: Data
        do {
            data = try BoundedFileReader.read(path: url.path, cap: maxCacheBytes)
        } catch {
            return FactsCache(loadFailure: "ignored the facts cache at \(url.path): \(error)")
        }
        let prefix = header(build: build)
        guard data.starts(with: prefix) else { return FactsCache() }
        do {
            let payload = try decodePayload(from: Data(data.dropFirst(prefix.count)))
            guard payload.tool == ToolInfo.name, payload.version == ToolInfo.version else { return FactsCache() }
            return FactsCache(entries: payload.entries)
        } catch {
            return FactsCache(loadFailure: "ignored the facts cache at \(url.path): \(error)")
        }
    }

    /// Best-effort persist: creates the directory, writes atomically, and
    /// reports an over-cap payload without failing the analysis.
    @discardableResult
    func persist(url: URL, build: String? = BuildIdentity.current) -> String? {
        guard let build else { return nil }
        let payload = Payload(tool: ToolInfo.name, version: ToolInfo.version, entries: entries)
        guard let data = try? Self.encodePayload(payload) else { return nil }
        let prefix = Self.header(build: build)
        guard data.count <= Self.maxCacheBytes - prefix.count else {
            try? FileManager.default.removeItem(at: url)
            return "deadwood: note: skipped facts cache larger than 64 MiB"
        }
        var file = Data(capacity: prefix.count + data.count)
        file.append(prefix)
        file.append(data)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? file.write(to: url, options: .atomic)
        return nil
    }
}

// MARK: - Fast AemiJSON coding (payload root)

// The nested model graph gets its fast
// `ADJSONFast{Encodable,Decodable}` conformance from `@JSONCodable` (the structs)
// and `FactsFastCoding.swift` (the enums + `ScopeID`). `Entry` and `Payload` are
// hand-written here so the root stays nested/`fileprivate` and — crucially — so
// `Payload` emits the top-level `entries` map in sorted key order: that alone
// makes the persisted cache byte-stable across a decode -> re-encode WITHOUT
// paying AemiJSON's `.sorted` whole-tape re-emit (it is the only hash-ordered
// container in the payload; every other collection is an array).

extension CachedFileArtifacts: AemiJSONFastEncodable, AemiJSONFastDecodable {
    func __adjsonEncode(into w: inout _JSONByteWriter) throws {
        w.beginObject()
        w.key("facts")
        try CachedFileFacts(facts).__adjsonEncode(into: &w)
        w.comma()
        w.key("directives")
        try w.encode(directives)
        w.comma()
        w.key("deadBranches")
        try w.encode(deadBranches)
        w.comma()
        w.key("degraded")
        try w.encode(degraded)
        w.endObject()
    }

    static func __adjsonDecode(_ c: _FastDecodeCursor) throws -> Self {
        Self(
            facts: try c.decode(CachedFileFacts.self, "facts").restored(),
            directives: try c.decode([SuppressionDirective].self, "directives"),
            deadBranches: try c.decode([UnusedCode].self, "deadBranches"),
            degraded: try c.decode([String].self, "degraded")
        )
    }
}

extension FactsCache.Entry: AemiJSONFastEncodable, AemiJSONFastDecodable {
    func __adjsonEncode(into w: inout _JSONByteWriter) throws {
        w.beginObject()
        w.key("fingerprint")
        w.string(fingerprint)
        w.comma()
        w.key("artifacts")
        try artifacts.__adjsonEncode(into: &w)
        w.endObject()
    }

    static func __adjsonDecode(_ c: _FastDecodeCursor) throws -> Self {
        Self(
            fingerprint: try c.string("fingerprint"),
            artifacts: try c.decode(CachedFileArtifacts.self, "artifacts"))
    }
}

extension FactsCache.Payload: AemiJSONFastEncodable, AemiJSONFastDecodable {
    func __adjsonEncode(into w: inout _JSONByteWriter) throws {
        w.beginObject()
        w.key("tool")
        w.string(tool)
        w.comma()
        w.key("version")
        w.string(version)
        w.comma()
        w.key("entries")
        w.beginObject()
        var first = true
        for (path, entry) in entries.sorted(by: { $0.key < $1.key }) {
            if first { first = false } else { w.comma() }
            w.dynamicKey(path)
            try entry.__adjsonEncode(into: &w)
        }
        w.endObject()
        w.endObject()
    }

    static func __adjsonDecode(_ c: _FastDecodeCursor) throws -> Self {
        Self(
            tool: try c.string("tool"),
            version: try c.string("version"),
            entries: try c.decode([String: FactsCache.Entry].self, "entries"))
    }
}
