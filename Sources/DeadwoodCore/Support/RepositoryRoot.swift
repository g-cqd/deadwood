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
enum RepositoryRoot {
    /// Walks up from `path` looking for a `.git` entry.
    ///
    /// Both a directory (an ordinary clone) and a file (a worktree or submodule,
    /// where `.git` is a pointer) count. Returns nil outside a repository, in
    /// which case fingerprints keep hashing the absolute path — there is no
    /// better anchor available, and behaviour is unchanged from before.
    static func detect(from path: String) -> String? {
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
    static func common(of corpus: [String]) -> String? {
        var found: String?
        for path in corpus {
            guard let root = detect(from: path) else { return nil }
            if let found, found != root { return nil }
            found = root
        }
        return found
    }

    /// `path` expressed relative to `root`, or unchanged when it lies outside.
    static func relativize(_ path: String, to root: String) -> String {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return path }
        return String(path.dropFirst(prefix.count))
    }
}
