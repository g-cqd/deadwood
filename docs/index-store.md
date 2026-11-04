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

## How the index is read

With an index, a declaration is judged by what the compiler recorded, not by its name. Four things are added to that, and only
where the index has nothing to say:

- **Witnesses of outside requirements.** A member the compiler records as overriding or witnessing a requirement that is defined
  outside the analyzed files (a protocol of the SDK or of another module, a framework class) is kept, whatever its name and wherever
  the conformance is written. The compiler records the witness at the conformance when that is in another file, and deadwood reads
  both places.
- **Matching a declaration to its symbol.** A declaration maps to a symbol by file, name and nearest line.
  - A store keeps the units of every build that wrote to it (another configuration, an earlier commit), so a symbol can be recorded
    at several lines; the nearest one wins. A declaration that is the only one of its name in its file maps to its symbol even when
    the line has drifted more than five lines.
  - The name is the index's name without its trailing argument labels, so a Swift Testing test named
    `` `handle(a) works` `` (index name `handle(a) works()`) maps.
  - A unit that could not resolve a type of a member's signature (a module missing from that build) records the member with an
    error type in its USR (`…startyXeXeF`), while a call from a unit that could resolve it records the resolved USR. They share the
    module, the types and the name, and deadwood links a call that matches no definition to the unresolved definitions that share
    that prefix (for an initializer, the type and the ending `fc`).
- **Roots that map to nothing.** A root (a view's `body`, `main`) that maps to no symbol is not seeded, so what it uses is rooted by
  name, looked up as below. A declaration that is not a root and does not map is left alone: its symbol is in the graph and is
  reached, with what it uses, if something uses it.
- **Uses the index lacks.** For each declaration with a body, deadwood asks the index which names the declaration's symbol refers to
  (with its accessors, observers and local functions, wherever the occurrences are) and compares them with the names its source
  uses. Not compared:
  - a name the declaration binds itself, whether the syntax declares it (a parameter) or only its text shows it (`if let x`,
    `guard let x`, `case let`, a closure's parameters, `for x in`, `error` in a `catch`), because the index never records a use of
    a local;
  - the label of a call such as `VStack(spacing: 8)`.

  A name that is left and that the index lacks is treated as a use, **but only if the declaration is itself reached from an entry
  point**. It is looked up as Swift looks up a bare identifier: the members of the enclosing type, then those it inherits (including
  extensions of the protocols and classes it conforms to), then the types around it, then the top level, taking declarations of the
  module and of the modules the file imports; the first level that declares the name is the answer. A member of something else
  (`view.spacing`) can be on any type, so every definition of the name stands for it. A type built as `Type(...)` is expected to
  have a recorded call of one of its initializers. A declaration nothing reaches adds nothing, so dead code stays dead.

On a complete index little is added: a body whose names the index records adds nothing, and the cases left are uses the compiler
cannot attribute, such as code a macro moves into a generated accessor (an `@Observable` property's `didSet`).

### Partial indexes

An index is partial when the build that wrote it skipped function bodies. Xcode's "prepare for indexing" does, and so do builds
that pass `-experimental-skip-all-function-bodies`. Such a store has the declarations and signatures and few or none of the uses
inside bodies. deadwood then recovers the uses by name, scoped as above, and the index note counts the declarations that needed it
("N with uses the index lacks"). The results are the best that can be had from that store, not the compiler's. For results that
are the compiler's, build the scheme in full (`xcodebuild build`, or a test run) and analyze that store. A count in that note that
is a large share of the declarations, findings on members a view's `body` obviously uses, and many more findings than the same
code gives without `--index-store-path`, all point to a partial store.

### Reusing a store

The units of builds that wrote to a store stay in it. A store reused across branches or commits is read correctly, since the
nearest line wins, but the extra units add references from code that no longer exists, which can keep a declaration alive after its
last use is gone. For an exact result, analyze a store written by one full build of the commit under analysis (a fresh
`-derivedDataPath`, or deleting `Index.noindex` before the build).

The database is kept under the cache root (`<root>/index/<hash>`; `--cache-path` moves it), not beside the store.
`libIndexStore.dylib` comes from the first trusted toolchain: `DEVELOPER_DIR`, `xcode-select -p`, `xcrun`,
`~/Library/Developer/Toolchains`, then the Command Line Tools. A trusted library is a regular file owned by root or you, neither it
nor its folder writable by group or others.
