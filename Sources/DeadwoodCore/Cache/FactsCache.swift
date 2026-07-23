//  Modeled on arcleak's FactsCache: fail-open per-file cache.

import Foundation

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

    private struct Payload: Codable {
        var tool: String
        var version: String
        var entries: [String: Entry]
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
            let payload = try? JSONDecoder().decode(Payload.self, from: data),
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
