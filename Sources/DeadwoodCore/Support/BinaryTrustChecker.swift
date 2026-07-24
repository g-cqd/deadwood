//  Lifted from SwiftStaticAnalysis (MIT) — Utilities/BinaryTrustChecker.swift.
//  Unchanged apart from being made `internal` (deadwood's index capability
//  is the only consumer) and the `unsafe`-marked C `stat` interop below,
//  which strict memory safety requires be spelled out.

import Foundation

// MARK: - BinaryTrustChecker

/// Defence-in-depth check that a binary or dylib path is safe to
/// `dlopen`/`exec` from this process. Refuses any path whose target is not
/// (a) a regular file (b) owned by root (c) not group- or world-writable.
///
/// The check gates `IndexStoreReader.findLibIndexStore`, which `dlopen`s a
/// `libIndexStore.dylib`. Without it a low-privilege user with write access
/// under `/Applications/Xcode.app/...`, `/Library/Developer/...`, or any
/// toolchain path that landed on disk via a non-installer flow could plant a
/// hostile binary that subsequent invocations would load.
enum BinaryTrustChecker {
    /// Returns `true` if `path` exists, is a regular file owned by uid 0, and
    /// is not writable by group or other. Symlinks are rejected by `lstat`:
    /// callers are expected to pre-resolve to a canonical path or accept this
    /// stricter posture.
    static func isTrusted(at path: String) -> Bool {
        guard !path.isEmpty else { return false }
        var info = stat()
        // SAFETY: `lstat` is a POSIX C call taking a NUL-terminated path and
        // an out-pointer to a caller-owned `stat`. `info` is a live stack
        // value for the duration of the call and the pointer never escapes,
        // so the `unsafe` interop is sound. Isolated to this one gate.
        guard unsafe lstat(path, &info) == 0 else { return false }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return false }
        guard info.st_uid == 0 else { return false }
        // Group- or world-writable binaries are tampering targets even when
        // nominally root-owned.
        if (info.st_mode & UInt16(S_IWGRP | S_IWOTH)) != 0 { return false }
        return true
    }
}
