#if canImport(FoundationEssentials)
    internal import FoundationEssentials
#else
    internal import Foundation
#endif

/// Finds the repository a corpus lives in, so fingerprints can be made
/// location-independent without the caller having to ask for it.
///
/// `--relative-to` fixes portability only if you remember to pass it: the same
/// code analysed with and without the flag shares *zero* fingerprints, so a
/// baseline written locally suppresses nothing in CI and vice versa — silently,
/// because a fingerprint that matches nothing looks exactly like a finding that
/// is genuinely new. That is the same silent-failure shape the flag exists to
/// remove.
///
/// So the fingerprint stops depending on how the run was spelled at all: it
/// hashes the path relative to the repository root, found here, whatever the
/// report is later formatted to show.
public enum RepositoryRoot {
    /// Walks up from `path` looking for a `.git` entry.
    ///
    /// Both a directory (an ordinary clone) and a file (a worktree or submodule,
    /// where `.git` is a pointer) count. Returns nil outside a repository, in
    /// which case fingerprints keep hashing the absolute path — there is no
    /// better anchor available, and behaviour is unchanged from before.
    public static func detect(from path: String) -> String? {
        var directory = URL(fileURLWithPath: path).standardized
        if directory.pathExtension == "swift" || !directory.hasDirectoryPath {
            directory = directory.deletingLastPathComponent()
        }
        while directory.path != "/" && !directory.path.isEmpty {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                return directory.path
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
    }

    /// The root shared by every file in `corpus`, or nil if they disagree.
    ///
    /// Disagreement means the corpus spans repositories (or none), and there is
    /// no single anchor that makes every fingerprint portable — so none is used.
    public static func common(of corpus: [String]) -> String? {
        var found: String?
        for path in corpus {
            guard let root = detect(from: path) else { return nil }
            if let found, found != root { return nil }
            found = root
        }
        return found
    }

    /// `path` expressed relative to `root`, or unchanged when it lies outside.
    public static func relativize(_ path: String, to root: String) -> String {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return path }
        return String(path.dropFirst(prefix.count))
    }
}

extension RepositoryRoot {
    /// A short, filesystem-safe key identifying the repository the current
    /// working directory belongs to (or the directory itself, outside one).
    ///
    /// The default facts cache used to be one global file per tool, so running
    /// against a second repository evicted the first's entries — content
    /// fingerprints kept that correct, but alternating projects never hit.
    /// Namespacing the default path by this key gives each workspace its own
    /// cache. FNV-1a over the root path: identity hashing, not security.
    public static func workspaceKey(from directory: String) -> String {
        let root = detect(from: directory + "/.") ?? directory
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in root.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16, uppercase: false)
    }
}
