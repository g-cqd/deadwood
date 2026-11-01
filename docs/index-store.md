# The index store (macOS)

`--index-store` replaces the name-based reachability graph with the compiler's index. Each reference resolves to the one symbol
the compiler recorded instead of to every declaration with the same name. It finds dead code that name matching conflated, and
clears false positives that cross modules. Roots, confidence, suppression and the rules are unchanged.

```sh
deadwood analyze --index-store Sources               # find the store
deadwood analyze --index-store-path .build/debug Sources
deadwood analyze --index-store-build Sources         # swift build first, if there is no store
deadwood analyze --index-store --verbose Sources     # explain which libIndexStore was chosen
```

The flag is off by default, so pass it on every run.

## Xcode projects

Build or test the project first so the index exists in DerivedData (the default folder, or one set with `-derivedDataPath`):

```sh
xcodebuild build -scheme App -derivedDataPath ~/Desktop/DerivedData
deadwood analyze . --index-store-path ~/Desktop/DerivedData/<Project>-<hash>/Index.noindex/DataStore
```

An Xcode project analyzed without an index prints a warning with this advice. It is raised when a path is, or directly contains,
an `.xcodeproj` or `.xcworkspace`: `deadwood analyze .` warns and `deadwood analyze Sources` does not.

## Swift packages

`swift build` writes the index under `.build` (each configuration, with its target triple, and `.build/out`); deadwood finds it
there, or in DerivedData matched to this checkout through `info.plist`, so separate worktrees do not share stores.

## When the index cannot be used

deadwood prints a warning that names what is lost and how to fix it, then runs name-based reachability. The exit code still follows
the findings. The warning appears on stderr, in the JSON `notes`, and as a SARIF `warning` notification. The causes:

- not macOS (`IndexStoreDB` is not linked elsewhere);
- no store found, or `--index-store-path` missing or not a store (a store, a `vN` directory, `Index.noindex`, a DerivedData build
  root or a SwiftPM build directory are accepted; nothing is created in anything else);
- the store cannot be opened, or `libIndexStore.dylib` is missing or not trusted;
- `--index-store-build` fails (it needs a `Package.swift` at the root and gives up after 600 seconds);
- the index covers none of the analyzed files.

An index that is stale is not a fallback. Declarations in files it does not cover are not judged, and the note says what to
rebuild: a file with no unit was never built by this scheme, a file newer than its unit changed since the build. What those files
use still counts by name, which is conservative. `--verbose` also counts symbols with no index reference.

Declarations the index cannot judge, locals, protocol requirements and their witnesses in the analyzed files, and the base types
of live subtypes are never flagged.

The database is kept under the cache root (`<root>/index/<hash>`; `--cache-path` moves it), not beside the store.
`libIndexStore.dylib` comes from the first trusted toolchain: `DEVELOPER_DIR`, `xcode-select -p`, `xcrun`,
`~/Library/Developer/Toolchains`, then the Command Line Tools. A trusted library is a regular file owned by root or you, neither it
nor its folder writable by group or others.
