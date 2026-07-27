#if canImport(FoundationEssentials)
    internal import FoundationEssentials
#else
    internal import Foundation
#endif

/// Canonical spelling of a source path.
///
/// `Finding.path` is part of the output contract: it is hashed into
/// `Finding.fingerprint`, which is what `--baseline` matches on and what SARIF
/// exports as `partialFingerprints`. So the same file must yield the same
/// string no matter how the corpus was named on the command line — `a.swift`,
/// `./a.swift` and `/abs/a.swift` are one file, analyzed once, fingerprinted
/// identically.
///
/// Without this, fingerprints computed from a directory walk (which
/// absolutizes) differ from those computed from explicit file arguments (which
/// did not), so a baseline written by one invocation style suppresses nothing
/// under the other. The same file passed under two spellings also entered the
/// corpus twice, inflating `analyzedFileCount` and double-counting its
/// declarations in the reachability graph.
enum SourcePath {
    /// The absolute, lexically standardized form — matching what the directory
    /// walk produces.
    ///
    /// `.standardized` is lexical on purpose: it collapses `.` and `..` without
    /// touching the filesystem, so canonicalizing a 2600-file corpus costs
    /// ~8 ms rather than 2600 `realpath` syscalls. The trade is that `..` is
    /// not resolved through a symlinked directory (`a/link/../b` standardizes
    /// to `a/b` even when `link` points elsewhere) — the same trade SwiftPM and
    /// SwiftLint make, and one no `git diff` output can trigger.
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardized.path
    }

    /// Canonicalizes every path and drops repeats, preserving first-seen order
    /// so the corpus stays deterministic for a given argument list.
    static func canonicalized(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        seen.reserveCapacity(paths.count)
        var result: [String] = []
        result.reserveCapacity(paths.count)
        for path in paths {
            let canonical = canonical(path)
            if seen.insert(canonical).inserted {
                result.append(canonical)
            }
        }
        return result
    }
}
