//  Modeled on arcleak's FactsCache: fail-open per-file cache.

// Fast, reflection-free JSON coders for the cache payload. `ADJSON.JSONEncoder`/
// `.JSONDecoder` are structs, have no `.outputFormatting` OptionSet, and no
// ADJSON type escapes this file — only the two seam functions below use it — so
// a plain (internal) import is enough.
import ADJSON
import Foundation

// MARK: - CachedFileArtifacts

/// Everything one parse of a file produces (facts, directives, dataflow
/// findings, degraded notes) — exactly what the Analyzer's per-file phase
/// computes, so a cache hit skips the parse and every per-file walk. The
/// corpus-wide graph/BFS and every rule always re-run: findings can never
/// go stale relative to rules or configuration.
@JSONCodable
struct CachedFileArtifacts: Sendable, Codable {
    let facts: FileAnalysisResult
    let directives: [SuppressionDirective]
    let deadBranches: [UnusedCode]
    let degraded: [String]
}

// MARK: - FactsCache

/// Per-file facts cache. Parsing + extraction dominate runtime; detection
/// is cheap and always re-runs, so only per-file artifacts are cached.
///
/// The cache is an optimization, so unlike configuration it FAILS OPEN: an
/// unreadable, corrupt, or version-mismatched cache behaves as empty and is
/// overwritten on persist. Entries are keyed by absolute path and validated
/// by a content fingerprint (FNV-1a 64 over bytes + length — identity, not
/// security; a collision merely serves stale facts for one file until its
/// next real change). A tool-version mismatch discards the whole cache, so
/// a facts-schema change can never deserialize into wrong shapes. The
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
        // ADJSON's single-pass byte writer over the reflection-free
        // `ADJSONFastEncodable` graph (`@JSONCodable` structs + `FactsFastCoding`
        // leaves). Default `.rfc8259` options — NO `keyOrder = .sorted`, which
        // would force ADJSON off the streaming writer into a second
        // compact -> re-parse-tape -> re-emit pass and cripple encode.
        // Determinism (a byte-stable round-trip across decode) instead comes from
        // `Payload.__adjsonEncode` emitting the top-level `entries` map in sorted
        // key order — O(files·log files), not a re-sort of the whole tape. The
        // cache is internal + version-gated, so `2.0`<->`2` and unescaped `/` are
        // harmless: only this tool version ever reads these bytes back.
        let encoder = ADJSON.JSONEncoder()
        return try encoder.encode(payload)
    }

    fileprivate static func decodePayload(from data: Data) throws -> Payload {
        // Byte-level decode: hand ADJSON a contiguous `[UInt8]` (no Foundation
        // `Data` bridging in the parser), and the `@JSONCodable`-generated
        // `_FastDecodeCursor` conformances read each field straight off the tape
        // by statically-known key — no `KeyedDecodingContainer`, no per-key String.
        let decoder = ADJSON.JSONDecoder()
        return try decoder.decode(Payload.self, from: [UInt8](data))
    }

    private(set) var entries: [String: Entry]

    init(entries: [String: Entry] = [:]) {
        self.entries = entries
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

    static func load(url: URL) -> FactsCache {
        guard
            let data = try? BoundedFileReader.read(path: url.path, cap: maxCacheBytes),
            let payload = try? decodePayload(from: data),
            payload.tool == ToolInfo.name,
            payload.version == ToolInfo.version
        else {
            return FactsCache()
        }
        return FactsCache(entries: payload.entries)
    }

    /// Best-effort persist: creates the directory, writes atomically, and
    /// swallows failures — a read-only cache location must never fail a run.
    func persist(url: URL) {
        let payload = Payload(tool: ToolInfo.name, version: ToolInfo.version, entries: entries)
        guard let data = try? Self.encodePayload(payload) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Fast ADJSON coding (payload root)

// `CachedFileArtifacts` and the whole nested model graph get their fast
// `ADJSONFast{Encodable,Decodable}` conformance from `@JSONCodable` (the structs)
// and `FactsFastCoding.swift` (the enums + `ScopeID`). `Entry` and `Payload` are
// hand-written here so the root stays nested/`fileprivate` and — crucially — so
// `Payload` emits the top-level `entries` map in sorted key order: that alone
// makes the persisted cache byte-stable across a decode -> re-encode WITHOUT
// paying ADJSON's `.sorted` whole-tape re-emit (it is the only hash-ordered
// container in the payload; every other collection is an array).

extension FactsCache.Entry: ADJSONFastEncodable, ADJSONFastDecodable {
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

extension FactsCache.Payload: ADJSONFastEncodable, ADJSONFastDecodable {
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
