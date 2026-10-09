# deadwood

Unused- and dead-code detection for Swift: unreferenced declarations and provably dead branches.

Built on [swift-syntax], modeled on [arcleak]: source-level analysis (no build
required), fixture-gated precision, a comment directive DSL for auditable
acceptance, baselines for adoption on legacy code, and SARIF for code scanning.

The engine (lifted from [SwiftStaticAnalysis], then consolidated):
declaration/reference collection over folded syntax trees, entry-point root
detection (@main, public API, @objc/IB, SwiftUI, operators, protocol
witnesses, raw-value enum cases, overrides, Equatable/Hashable synthesis),
reachability across the corpus on an integer-indexed graph
(direction-optimizing parallel BFS), SCCP dead branches and
liveness/reaching-definitions dead stores per function body, and an
incremental fail-open facts cache.

## Rules

| rule | default | finds |
| --- | --- | --- |
| `unused-function` | on | functions/methods unreachable from any entry point |
| `unused-type` | on | types nothing references (members collapse into the type) |
| `unused-property` | on | stored/computed properties with no reference |
| `unused-enum-case` | on | cases never constructed or matched (raw-value/Codable/CaseIterable enums exempt, including conformances added via extension) |
| `unused-transitively` | on | declarations only dead code uses, reported in the same run as the dead code, grouped under it and naming its dead users (confidence: the weakest along the chain) |
| `dead-branch` | on | branches whose condition provably folds to a constant |
| `referenced-only-by-tests` | on (fires only under `--production`) | declarations reachable with test roots but unreachable without them |
| `preview-only` | on, note | production code only `#Preview` bodies and `PreviewProvider` types use: it ships in release builds for nothing |
| `debug-only` | on, note | production code only `#if DEBUG` code uses: it ships in release builds for nothing |
| `unused-import` | off | imports with no referenced symbol in the file (syntax-level heuristic; `@_exported` is never flagged) |
| `unused-public-api` | off | public declarations unreferenced inside the corpus (public API is a root otherwise) |
| `assign-only-property` | off | stored properties whose every reference is a write |
| `dead-store` | off | assignments overwritten before any read (liveness + reaching definitions) |

Two analysis shapes:

- `deadwood analyze <dirs>` — corpus mode: reachability from entry points
  across every file.
- `Analyzer.analyze(source:path:)` — single-file mode (what the fixture
  golden gate runs): only declarations *effectively private to the file*
  can be judged, because an internal declaration may be used from any other
  file of its module. Cross-file verdicts need corpus mode.

## Entry points

Reachability starts from the roots below. A root is never reported, and
everything it uses stays used. Each reason is the `RootReason` the rule
returns, in `Sources/DeadwoodCore/Engine/RootDetection.swift`.

**Swift declarations**

- `@main`, `@UIApplicationMain`, `@NSApplicationMain`; a `main` function; a
  static `main()`.
- Public and open declarations, unless `unused-public-api` is enabled, which
  judges them like internal ones.
- `@objc` and `@objcMembers`, including KVO-observed `@objc dynamic`
  properties (on by default, `treatObjcAsRoot`). A `dynamic` member without
  `@objc` is not a root.
- Interface Builder attributes: `@IBAction`, `@IBOutlet`, `@IBInspectable`,
  `@IBDesignable`, `@IBSegueAction`.
- Codable and raw-value requirements: a `CodingKeys` enum, stored properties of
  a type conforming to `Codable`, `Encodable` or `Decodable`, and cases of
  raw-value or `CaseIterable` enums, which other code constructs.
- `@dynamicMemberLookup` and `@dynamicCallable` types.
- Operator functions; `@resultBuilder` members; `wrappedValue` and
  `projectedValue` of property wrappers; `@_silgen_name`, `@_cdecl`,
  `@_dynamicReplacement`, `@_objcRuntimeName`.
- Overrides of a superclass member.
- Protocol witnesses of a protocol or superclass declared outside the
  analyzed files. A member whose name a cataloged protocol requires is kept
  (`Equatable`, `Hashable`, `Codable`, `CustomStringConvertible`,
  `Identifiable`, `Sequence`, SwiftUI `View`, ArgumentParser, and others). A
  type conforming to an uncataloged external type, such as `UIResponder`,
  `NSManagedObject` or `UIWindowSceneDelegate`, keeps all its non-private
  members. `@NSManaged` members are kept at any access level, `private`
  included, because Core Data reaches them by name at runtime.
- SwiftUI `App` and `View` types, `body`, `PreviewProvider`, and SwiftUI
  property wrappers; App Intents, App Shortcuts and Widget conformers.
- Test code: functions named `test…` or annotated `@Test`; `@Suite` types,
  types holding `@Test` functions, and `XCTestCase` subclasses, at any depth.
- File-scope code: top-level statements and `#Preview` bodies.
- Everything in a generated file (see "Generated code" below).

**Project files**

The types a project file names are roots, matched by their name without the
module prefix (`$(PRODUCT_MODULE_NAME).SceneDelegate` becomes `SceneDelegate`).
Only classes, structs, enums and actors match.

- Info.plist keys at any nesting depth: `NSExtensionPrincipalClass`,
  `NSPrincipalClass`, `UISceneDelegateClassName`, `UISceneClassName`,
  `WKExtensionDelegateClassName`, `WKApplicationDelegateClassName`,
  `CLKComplicationPrincipalClass`.
- `INFOPLIST_KEY_<key>` build settings in `project.pbxproj`, with the same keys.
- `customClass` attributes in storyboards and xibs.

A scene or app delegate that nothing names (no plist key, no build setting,
no code reference) is reported as an unused type. A delegate that code names,
such as `config.delegateClass = SceneDelegate.self` in the app delegate, is
kept.

## Recommended configuration for real-world use

deadwood's precision depends heavily on **what you point it at**. Its default
syntax reachability is a name-based graph over the files you pass — so a
declaration referenced only from a file *outside* that set reads as unused.
Empirically, on app codebases with rich test/preview suites the default mode's
"unused" findings are a mix of genuinely deletable code and code that is live
through a path the source-only graph can't see. Configure accordingly:

- **Analyze the whole module, tests included.** Pass the test target
  alongside the sources (`deadwood analyze Sources Tests`). The single biggest
  false-positive class is production code referenced only from tests; including
  the test target removes it. Pair with **`--production`** to then surface
  those as their own `referenced-only-by-tests` findings instead of hiding
  them.
- **For a real "safe to delete" signal, use the index store (macOS).** The
  compiler index resolves cross-file/cross-target/dynamic references and
  disambiguates same-named symbols the name graph conflates — it is the
  accuracy mode. On SwiftStaticAnalysis it cleared a name-conflation false
  positive and surfaced 58 genuinely dead declarations the syntax mode missed.
  For an Xcode project it is the recommended configuration; see
  [Index-store mode](#index-store-mode-macos). Without an index it warns and
  falls back to name-based reachability.
- **Keep the opt-in rules opt-in.** `unused-import` and `unused-public-api` are
  deliberately off by default: the import heuristic can't see extension or
  operator usage (it over-reports — hundreds of findings on a real corpus),
  and public API is a library's *surface*, not dead code. Enable them only on
  application targets, and treat them as review prompts, not deletion lists.
- **OS-discovered, project-file, preview and script entry points.** Types
  the system instantiates by conformance (`AppShortcutsProvider`, App Intents,
  Widgets) are rooted automatically, and so are the types project files name:
  an Info.plist's `NSExtensionPrincipalClass`, `NSPrincipalClass` or scene
  delegate, their `INFOPLIST_KEY_` build settings, and storyboard or xib
  `customClass` attributes. Point deadwood at directories, which it searches
  for these files, or pass the files explicitly. Code at file scope, such as a
  `#Preview` body or a script's top-level statements, is an entry point too.
  Code only previews or `#if DEBUG` code use counts as used; when it is
  production code, `preview-only` and `debug-only` notes suggest moving it
  under `#if DEBUG`.
- **Test suites.** `@Suite` types, types holding `@Test` functions at any
  depth, and `XCTestCase` subclasses are entry points, whatever their names.
- **Generated code.** A file whose header names a generator ("Generated
  using", "@generated", "DO NOT EDIT"), or that sits in a `Generated`
  directory, is never reported on; what it uses stays used. A note per such
  file counts the declarations nothing outside it names.
- **Accept intentional scaffolding** (author-your-own template stubs, debug
  helpers) with `// @dw:accept -- reason` so the decision is on record rather
  than re-flagged every run.

Bottom line: for an Xcode project, `deadwood analyze . --index-store-path <DerivedData>/<Project>-<hash>/Index.noindex/DataStore` after a build is the high-precision configuration; for a package, `deadwood analyze Sources Tests --index-store` on macOS is. Plain `deadwood analyze Sources` is the fast,
zero-setup pass whose findings you review rather than delete blindly.

## Production mode

`deadwood analyze --production Sources Tests` computes reachability twice
over the same graph: once with test entry points (test methods, XCTestCase
subclasses, @Suite types, tests-glob files) and once without. Declarations
only tests can reach get the `referenced-only-by-tests` rule — not dead
(the tests would break), but nothing in production uses them. Genuinely
unreachable declarations keep their normal rules, and the rule never points
into test code itself. `testsGlob` in `.deadwood.json` overrides the
built-in `**/Tests/**` + `**/*Tests.swift` heuristics.

## Index-store mode (macOS)

For an Xcode project, run deadwood in index-store mode: it is the recommended
configuration, and the one this section documents first. The flag is off by
default, so pass it (or `--index-store-path`) on every run.

`deadwood analyze --index-store Sources` swaps the reachability oracle from
the name-level syntax graph to the compiler's **index store** (IndexStoreDB),
resolving each reference to the one USR the compiler recorded rather than to
every same-named declaration. This is the deferred M2: ~95% cross-module
precision. Everything else — root detection, the confidence model, member
collapse, suppression, the `unused-*` rules — is unchanged; only reachability
is resolved more precisely, so the finding set differs exactly where the
index is more accurate (it both *finds* dead code the name graph conflated
away and *clears* false positives it raised for cross-module references).

### Xcode projects

Build or test the project with `xcodebuild` first. That writes the index into
DerivedData at `<DerivedData>/<Project>-<hash>/Index.noindex/DataStore`. The
default DerivedData folder is `~/Library/Developer/Xcode/DerivedData`; a custom
location, such as `~/Desktop/DerivedData` set with `-derivedDataPath`, works
the same way.

```sh
xcodebuild build -scheme App -derivedDataPath ~/Desktop/DerivedData   # or: xcodebuild test
deadwood analyze . --index-store-path ~/Desktop/DerivedData/<Project>-<hash>/Index.noindex/DataStore
```

The index keys every reference by its USR, the compiler's unique symbol name.
Same-named symbols in different packages and the app target therefore stay
distinct instead of being conflated by name, and a declaration used only from
another package is kept on the strength of that use.

Two warnings say when this mode is not in effect. Both go to stderr and to the
JSON `notes`, and in SARIF they are `warning`-level `toolExecutionNotifications`.
Neither changes the exit code.

- An Xcode project analyzed with no index-store flag prints
  `deadwood: warning: analyzing an Xcode project without the index store;
  findings use name-based reachability. Pass --index-store-path
  <DerivedData>/<Project>-<hash>/Index.noindex/DataStore for precise
  cross-module results.`
- A requested index store that cannot be used prints a warning naming what is
  lost and how to fix it, then runs name-based reachability. The reasons are no
  index store found, an index store that fails to open, a failed auto-build, and
  a missing `libIndexStore.dylib`.

### Swift packages

```sh
swift build                                  # generate the index first
deadwood analyze --index-store Sources       # USR-precise reachability
deadwood analyze --index-store-path .build/out Sources   # explicit store
deadwood analyze --index-store-build Sources # run `swift build` if none found
```

For a package, deadwood discovers the index under the project's
`.build/debug/index/store`, the new SwiftPM build system's `.build/out`
(versioned `vN/records`), or Xcode DerivedData. `--index-store-build` runs
`swift build` when none is found.

A missing index never fails a run. On Linux, where IndexStoreDB's
`libIndexStore.dylib` discovery is macOS-only, `--index-store` prints a warning
and runs name-based reachability. Without any index-store flag, the analysis is
the syntax analyzer's, apart from the Xcode-project warning above.

Conservatism carries over from the syntax graph: declarations the index
cannot judge (unmapped), locals, in-corpus protocol requirements and their
witnesses, and base types of live subtypes are never flagged, so the index
oracle does not manufacture false positives from coverage gaps or dispatch.

## Experimental: embedding confidence

`deadwood analyze --experimental-embedding-confidence` (macOS) *annotates*
each finding with a semantic-anomaly score and changes nothing about which
findings fire. It embeds every flagged declaration's snippet and scores each
as a kNN outlier among its peers — a declaration whose code is a semantic
outlier among the other candidates is a softer or harder bet on being
genuinely dead. The score and the model that produced it appear in the note
(`embedding-confidence: N% anomaly [experimental, <provider>]`), and the
stderr summary names the provider too: which model scored a run changes how
the number should be read, so it is never left implicit.

The default provider is Apple's system `NLContextualEmbedding` — zero
third-party download, with a deterministic n-gram provider as the fallback
when the system asset is unavailable. Be honest about what it is: an
*English natural-language* model, not a code-trained one. On code it maps
unrelated declarations into one narrow region of the vector space, so the
anomaly spread compresses and the annotation discriminates less.

```sh
# score with a code-trained Core ML + HuggingFace bundle instead
deadwood analyze --experimental-embedding-confidence \
  --embedding-bundle ~/Models/MiniLM Sources
```

`--embedding-bundle <dir>` (macOS; only meaningful together with
`--experimental-embedding-confidence`) points at a directory holding both a
Core ML model — `.mlpackage`, compiled on first use, or a prebuilt
`.mlmodelc` — and its WordPiece vocabulary (`vocab.txt`, or the vocab inside
`tokenizer.json`). Snippets are truncated to 128 tokens, the MiniLM-class window.

**WordPiece (BERT-family) bundles** — all-MiniLM-L6-v2 and friends. deadwood
tokenizes in-house (`WordPieceTokenizer`, pinned token-for-token against
`swift-transformers` before that dependency was dropped) rather than linking a
9-package HuggingFace stack into every binary. A BPE or SentencePiece bundle
fails to load and falls back to the default provider rather than tokenizing
wrongly.

**Pick a *sentence-embedding* model, not a masked-LM checkpoint.** Byte-level BPE
support shipped briefly in v0.6.0 to allow CodeBERT, then was withdrawn once
measured: on Bilbary's 29 findings the anomaly-score spread was all-MiniLM-L6-v2
**36-77%** (18 distinct values, stdev 10.96), Apple NLContextual 2-8% (7 values,
stdev 1.76), **CodeBERT 1-3% (3 values, stdev 0.68)** — the worst of the three. A
masked-LM checkpoint produces anisotropic vectors: everything crowds into one
cone, the scores collapse, and the signal is useless. MiniLM is contrastively
fine-tuned for cosine comparison, which is what this scoring needs.

With no flag, deadwood looks for a model shipped beside the binary —
`<exec-dir>/Models/MiniLM`, then the FHS-style
`<exec-dir>/../share/deadwood/Models/MiniLM` — so a distribution that ships
one uses it automatically. `DEADWOOD_EMBEDDING_BUNDLE` overrides that
location, and takes precedence over both.

Every step degrades rather than fails: a bundle that will not load falls
through to the on-device provider with a note on stderr, and where
NaturalLanguage/CoreML are unavailable the flag reports itself unavailable
and leaves notes untouched. The signal only annotates — no bundle, present or
broken, can change which findings fire or the exit code.

## Confidence model

Every finding's note carries its confidence, and the same level is a structured `confidence` field in the JSON report and SARIF `properties.confidence`. The levels:

- **certain** — dataflow proofs on literal conditions (`if false`); a dead
  branch proven by propagating a variable is **high**.
- **high / medium / low** — by *effective* visibility: private/fileprivate
  high, internal medium, package/public/open low (a member of a private
  type is effectively private).
- **Demotions** for dynamic-reference risk: a name appearing inside a
  string literal outside the declaration itself and outside generated files
  (NSClassFromString-style lookup) forces low with a note; members of
  NSObject subclasses without `@objc` demote one step (selector machinery may
  reach them). Demoted findings still fire — risk lowers confidence, it
  never hides dead code.
- A name that a comment still mentions, as commented-out code does, adds a
  note but never lowers the confidence.

## Facts cache

Corpus runs reuse per-file artifacts (facts, directives, dataflow findings)
through a fail-open cache. Each entry is keyed by its file content and the full
configuration; the cache also records the executable's file identity and tool
version. Rebuilding or replacing the executable starts a cold cache, even if
the version string stays the same. The cache is rebuilt from the current run's
files, so absent files are pruned. Detection always re-runs.

On by default (default location `~/Library/Caches/deadwood/<workspace>/facts.json`,
one file per repository; `--cache-path` sets an explicit file, best kept
outside the analyzed repository, where writing it would change the working
tree on every run; `--no-cache` disables it). The cache serializes through
[AemiJSON](https://github.com/g-cqd/AemiJSON)'s reflection-free JSON path.
References keep only the fields corpus-wide analysis reads, so repeated file
paths and unused source positions do not fill the cache. A cache over the
64 MiB read cap is not written. A full-hit run skips parsing, per-file
extraction, and the redundant cache write. A mismatched header is a
silent miss. A corrupt body under a matching header is reported once on
stderr and replaced after a complete analysis.

## CLI

```sh
deadwood analyze Sources            # xcode-format diagnostics, exit 1 on errors
deadwood analyze --format sarif .   # SARIF 2.1.0 (also: --format json)
deadwood analyze --strict Sources   # exit 1 on any warning or error; notes never fail
deadwood analyze --production .     # split "only tests reach this" findings
deadwood analyze --no-cache .       # disable the (default-on) facts cache
deadwood analyze --index-store .    # USR-precise cross-module reachability (macOS; needs `swift build`)
deadwood analyze --experimental-embedding-confidence --embedding-bundle ~/Models/MiniLM .
deadwood analyze --minimum-confidence high .  # report only high and certain findings
deadwood analyze --only-from changed.txt --report-new-since base.json .  # also report dead code the change created
deadwood rules                      # list rules; `rules <id>` explains one
```

`--minimum-confidence <low|medium|high|certain>` reports only findings at or above that level of the [confidence model](#confidence-model) above. Findings without a confidence are always reported, and the flag applies before `--baseline` and `--write-baseline`, so a baseline written with it holds only what the same flag would report.

`--report-new-since <baseline>` promotes the findings outside `--only` that the baseline does not hold into the report. It needs `--only` or `--only-from`; see [Newly dead code outside the changed files](#newly-dead-code-outside-the-changed-files).

The flags, exit codes and JSON fields that 1.x freezes are listed in [CLI and JSON contract (1.x)](#cli-and-json-contract-1x).

## CLI and JSON contract (1.x)

The contract is versioned by the JSON `schemaVersion` (currently 1) and holds for every 1.x release, even while deadwood's own version is 0.x.

Within 1.x, `deadwood analyze [paths…]`, the flags below, the exit codes and the JSON fields do not change incompatibly. Adding a flag or a field is not a breaking change.

JSON goes to stdout and stderr is free-form text, so do not merge them with `2>&1`. A document without `schemaVersion` is not a 1.x report.

Outside the freeze: `--experimental-embedding-confidence`, `--embedding-bundle` (and the `DEADWOOD_EMBEDDING_BUNDLE` variable), the free-form text of `deadwood rules`, and the `DeadwoodCore` library API.

| Flag | Meaning |
|---|---|
| `--format` | `xcode` (default, build-log lines), `json` (the report below) or `sarif` (SARIF 2.1.0) |
| `--only <path>`, `--only-from <file>` | report only these files; `--only` is repeatable, and `--only-from` reads one path per line (`-` reads stdin). See [Report scope](#report-scope) |
| `--relative-to <dir>` | print paths relative to `<dir>`; it also anchors fingerprints. See [Baselines and fingerprints](#baselines-and-fingerprints) |
| `--baseline <file>`, `--write-baseline <file>` | drop the findings a baseline holds; write the current findings as a baseline, then exit `0` |
| `--report-new-since <file>` | report findings outside `--only` that a base-branch baseline does not hold. See [Newly dead code outside the changed files](#newly-dead-code-outside-the-changed-files) |
| `--config <file>` | configuration file; default `./.deadwood.json` when present |
| `--cache-path <file>`, `--no-cache` | facts-cache file; disable the cache. See [Facts cache and parallel jobs](#facts-cache-and-parallel-jobs) |
| `--strict` | warnings fail the gate too; notes never do |
| `--minimum-confidence <level>` | report only findings at or above `low`, `medium`, `high` or `certain`; findings without a confidence are always reported |
| `--include <regions>`, `--exclude <regions>` | comma-separated `preview`, `debug`, `test`, `mock`, `generated`, `script` or `all`: analyze as first-class code, or keep out of scope |
| `--index-store`, `--index-store-path <path>`, `--index-store-build` | USR-precise cross-module reachability from the compiler's index store (macOS). `--index-store-path` names the store, and `--index-store-build` runs `swift build` when none is found; each implies `--index-store` |

### Exit status

The exit codes below do not change incompatibly within 1.x; [Exit codes](#exit-codes) summarizes them. deadwood does not use `74`.

- **`0`**: the gate passed. Without `--strict`, no finding has `error` severity; with it, no finding is a `warning` or an `error`. Notes never fail a run. `--write-baseline` exits `0` whatever the findings.
- **`1`**: findings only. Without `--strict`, it means a finding has `error` severity; with `--strict`, any finding that is a `warning` or an `error`. A rule's severity is `warning` by default (`note` for `preview-only` and `debug-only`), and the configuration can set it per rule. Only findings in the report count: one removed by `--baseline` or `--minimum-confidence`, one out of scope, and one suppressed do not. A finding promoted by `--report-new-since` does.
- **`64`**: usage. An argument that does not parse (an unknown flag or an invalid value); `--write-baseline` with `--only` or `--only-from`; `--report-new-since` without `--only` or `--only-from`; `--only-from -` together with `-` as an input; an input path that does not exist; an input with no Swift files; an `--only-from` file that is unreadable, not a regular file, or over 4 MiB; an unknown region name on the command line.
- **`70`**: nothing was analyzed. A cancelled run prints nothing on stdout. When every file was skipped (unreadable, not UTF-8, or over 10 MiB), the report is still printed in the requested format and the run exits `70`. A report on stdout means nothing could be analyzed; empty stdout means the run itself failed.
- **`78`**: a configuration or baseline is unusable. The configuration file (`--config`, or `./.deadwood.json`) is unreadable, over 1 MiB, malformed, names an unknown rule, or names an unknown region. A `--baseline` or `--report-new-since` file is missing, not a regular file, over 1 MiB, malformed, or has a `version` other than `1`; the `--report-new-since` baseline is read before the analysis starts. A `--write-baseline` file that cannot be written also exits `78`.

### Report scope

- The whole corpus is analyzed, because reachability spans files. Only the report is scoped.
- A finding is kept when its location is in scope, and only kept findings decide the exit code.
- Scope entries and finding paths are canonicalized the same way: standardized, with symlinks resolved. A relative entry resolves against the working directory. `--relative-to` changes how paths print and how fingerprints are anchored (see below), never which findings are kept.
- An empty scope (an empty `--only-from` file) keeps no finding: `findings` is empty and the exit status is `0`.
- Out-of-scope findings are not printed. The JSON report lists them in `outOfScope`, and the summary counts them. Suppressed findings are not scoped: `suppressed` lists them for the whole corpus.
- A non-empty scope that matches no analyzed file prints a warning on stderr. The exit status still follows the findings.
- The exception is `--report-new-since`, which promotes out-of-scope findings whose fingerprint the baseline does not hold. Its rules are in [Newly dead code outside the changed files](#newly-dead-code-outside-the-changed-files), and with it the no-match warning is not printed.

### JSON report

`--format json` prints one object on stdout. Optional keys are omitted when they have no value, never written as `null`.

| Field | Meaning |
|---|---|
| `schemaVersion` | integer, `1` today; the contract version shared by arcleak, dolly and deadwood |
| `findings` | reported findings: in scope, not suppressed, not baselined, at or above `--minimum-confidence` |
| `suppressed` | findings silenced by an `@dw:` directive, each with `finding` and `reason`; `reason` is omitted when the directive gave none |
| `outOfScope` | findings outside `--only` / `--only-from` |
| `degradedFiles` | files skipped or only partly analyzed, each with `path`, `detail` and `skipped` (`false` when only part of the file was skipped) |
| `analyzedFileCount` | files analyzed |
| `cacheHits`, `cacheMisses` | facts reused from the cache, and facts parsed; both `0` without a cache |
| `cacheLoadFailure` | optional string; present only when the facts cache was ignored as unreadable or undecodable |
| `notes` | informational notes, also printed on stderr |
| `wasCancelled` | `false` in every printed report: a cancelled run prints nothing and exits `70` |

Each element of `findings`:

| Field | Meaning |
|---|---|
| `rule`, `severity` | rule id (`deadwood rules` lists them); `note`, `warning` or `error` |
| `path`, `line`, `column` | location, absolute or relative to `--relative-to`; `line` and `column` are 1-based, and `column` counts UTF-8 bytes |
| `message` | one-line description |
| `note` | optional; omitted when there is none. It begins with `confidence <level> — ` |
| `confidence` | optional; `certain`, `high`, `medium` or `low`; omitted when the finding was not scored |
| `fingerprintPath` | optional; the path the fingerprint hashes. Set when every analyzed file is in one git repository (relative to its root), and for paths under a `--relative-to` directory; omitted otherwise |
| `fingerprint` | stable identity, as hex; the value `--baseline` matches in the same run |

`schemaVersion` changes only when a field is removed, renamed, retyped, made required or optional, or changes meaning, or when the closed set of severities changes. Adding a field does not change it. Rule ids are an open set: a new rule can appear in any 1.x release, so consumers must handle a rule id they do not know. Consumers ignore unknown fields and reject a `schemaVersion` above the one they were written for.

### Facts cache and parallel jobs

- **Location.** `deadwood/<key>/facts.json` under the user's caches directory (`~/Library/Caches` on macOS). The key is a hash of the git repository root that contains the working directory, or of the working directory itself outside a repository. It follows where deadwood runs, not which paths it analyzes.
- **Validation.** Entries are keyed by absolute path and checked against the file's content (a 64-bit FNV-1a hash and its byte count) and the whole configuration. The header records the tool version and the executable's file identity, so a rebuilt executable starts with an empty cache, silently. The content hash is not cryptographic: a collision can serve stale facts for one file until that file next changes.
- **Writes.** A run that changes the cache writes the whole file atomically, rebuilt from its own files, so deleted files are pruned. There is no lock: concurrent runs can lose each other's new entries (the last writer wins), and a reader never sees a partial file.
- **Damage and size.** A corrupt body under a matching header is ignored with a note (on stderr, and as `cacheLoadFailure` in JSON) and replaced after a complete analysis. A cache file over 64 MiB is ignored with the same note. A payload over 64 MiB is not written, and an existing file is removed, with a note.
- **Parallel CI jobs on one machine** should each pass their own `--cache-path`, outside the analyzed tree, so they neither lose entries nor evict each other's. `--no-cache` disables reads and writes, and overrides `--cache-path`.

### Baselines and fingerprints

- **Format.** A baseline is JSON with `fingerprints` (sorted), `tool` and `version`, and `version` is `1`. A baseline with another `version` is refused with exit `78`; `tool` is not checked. A file over 1 MiB is refused too.
- **Fingerprint.** `fingerprint` is the FNV-1a 64-bit hash, in hex, of `rule|path|line|column|message`. The path is the finding's `fingerprintPath` when it has one, and the absolute path otherwise.
- **Anchor.** When every analyzed file is in one git repository, `fingerprintPath` is relative to that repository's root, so a baseline matches on any checkout. Outside a repository the absolute path is hashed, so a baseline does not move between machines.
- **`--relative-to`.** Given the repository root (`--relative-to .` at the root), it changes only the printed paths, and the fingerprints equal the automatic anchor. Any other directory re-anchors the findings under it, and findings outside it keep the repository anchor. Outside a repository it changes the hashed path too. Pass the same `--relative-to` value to the run that writes a baseline and to every run that reads it.
- **Edits move findings.** `line` and `column` are hashed with the message, so an edit above a baselined finding re-reports it. Regenerate the baseline after large moves.
- **Writing.** `--write-baseline` records the findings the report would show: after `--minimum-confidence` and `--relative-to`, so a baseline written with the flag holds only what the same flag reports. It needs an unscoped run (exit `64` with `--only` or `--only-from`), ignores `--baseline`, and exits `0`.

## Accepting a finding

Directives use the `@` sigil with the `@dw:` or `@deadwood:` namespace:

```swift
// @dw:accept -- <why this finding is intentional>
// @dw:accept:this <rule|all> [-- reason]
// @dw:disable <rule|all> … // @dw:enable <rule|all>
```

Accepted analysis limits are cataloged in
`Tests/DeadwoodCoreTests/Fixtures/KnownGaps.md`, each pinned by a test.

## Using it as a pull-request gate

The corpus is always **everything**; only the *report* is scoped. Passing a
pull request's changed files as the input produces a different and wrong
answer, because these are whole-program analyses — deadwood decides "unused" by finding no reference anywhere, so shrinking the corpus makes live declarations look dead. Measured on a real 16-file pull request: 0 findings whole-corpus, 6 false positives when those files *were* the corpus.

```sh
git diff --name-only origin/main... -- '*.swift' > changed.txt
deadwood analyze . --only-from changed.txt --baseline .deadwood-baseline.json --strict
```

`--only` (repeatable) and `--only-from <file|->` scope the report. Findings
outside the scope are kept on `outOfScope` and counted in the summary, so a
scoped run can never be mistaken for a clean one. An empty scope reports
nothing — a pull request that changed no Swift is not a licence to report the
whole repository.

### Fingerprints are portable by default

`Finding.fingerprint` — what `--baseline` matches and what SARIF exports as
`partialFingerprints` — hashes the path **relative to the repository root**,
found by walking up for `.git`. So a baseline committed to the repository
matches on any machine, and it does not matter whether the corpus was named as
a directory or as an explicit file list, or where the checkout lives.

`--relative-to <dir>` additionally changes the paths that are *displayed* (and
re-anchors fingerprints to that directory, which from the repository root is
the same anchor). SARIF uris must be repository-relative for code scanning to
link them, so pass it when uploading SARIF.

### Newly dead code outside the changed files

A pull request can leave a declaration in an unchanged file dead: it removes
the last use. `--only` hides that finding, because the declaration is outside
the changed files. `--report-new-since <baseline>` reports it. The baseline is
the base branch's, written unscoped with the same paths, `--relative-to`, and
configuration as the pull request's run:

```sh
# on the base branch
deadwood analyze . --relative-to . --write-baseline base.json

# on the pull request
git diff --name-only origin/main... -- '*.swift' > changed.txt
deadwood analyze . --relative-to . --only-from changed.txt --report-new-since base.json --strict
```

- A finding outside the scope whose fingerprint the baseline does not hold
  moves into the report. A finding the baseline holds stays out of scope and
  is still counted in the summary.
- An empty scope still promotes. A promoted finding that `--baseline` also
  holds is suppressed like any other, and a promoted finding counts toward
  exit `1`.
- A promotion prints `N finding(s) outside --only are new since <file>` to
  stderr and into the JSON `notes`. When the baseline matches none of the
  findings the run reports or leaves out of scope, it also says the baseline may
  not match the corpus. That is a hint, not a diagnosis.
- The `--only scope matches no analyzed file` warning is not printed, so a
  pull request that only deletes a file can name it in `--only`.
- `--report-new-since` needs `--only` or `--only-from`, and cannot be combined
  with `--write-baseline`. A missing or malformed baseline exits `78`.

Two caveats:

- A declaration that was already dead, but whose finding's message changed, is
  reported again as new. Transitive findings name their dead users (`is only
  used by dead code: …`) and a dead cycle names its members. When the change
  deletes one of those users, the message changes from "only used by dead
  code" to "never referenced", so the fingerprint is new.
- Fingerprints depend on `--relative-to`. Pass the same value to the baseline
  run and to the pull request run; otherwise the findings differ from the
  baseline's and read as new.

### SARIF locations

Every `artifactLocation.uri` in `--format sarif` is an RFC 3986 URI
reference, in one of two forms, the convention arcleak and dolly share:

- **Relative**, when `--relative-to <dir>` is given, the file lies inside
  `<dir>`, and its path below `<dir>` is made only of `A–Z a–z 0–9`,
  `- . _ ~ ! $ & ' ( ) * + , = @` and `/`: the uri is that path, unescaped
  (`Sources/App/Box.swift`), with `"uriBaseId": "SRCROOT"`. The run's
  `originalUriBaseIds.SRCROOT.uri` is `<dir>` as a `file://` URI ending in `/`.
- **Absolute** otherwise: `file://` and the absolute path, every other byte
  percent-encoded as UTF-8 (`file:///Users/me/My%20Repo/Sources/Box%231.swift`),
  with no `uriBaseId`. Without `--relative-to`, every location takes this form.

Degraded-file notes follow the same rules. Paths are canonical — absolute,
symlinks resolved, and on macOS without `/private` (`/var/folders/…`,
`/tmp/…`) — whichever spelling of `<dir>` or of the analyzed paths the command
line used: through a symlink, or with `/private`.

A relative uri is never percent-encoded, so a reader that takes it as a plain
path still finds the file. A path that would need escapes — a space, a `#`,
any non-ASCII letter — is written as an absolute `file://` URI instead, which
every reader decodes. Those uris name the checkout, so they are the one part
of a `--relative-to` report that depends on where the repository lives;
GitHub code scanning converts absolute uris under the checkout directory to
relative ones.

SARIF columns count UTF-16 code units, and the run says so
(`"columnKind": "utf16CodeUnits"`: SARIF requires a run with results to
declare its unit, and this is the one consumers assume and editors index
lines in); a byte-order mark does not count. The `xcode` and `json` formats
keep swift-syntax's 1-based UTF-8 byte columns, the unit compilers print and
the one fingerprints hash.

### Scope-file hygiene

Scope lines tolerate CRLF endings and strip git's simple C-quoting, but paths
with non-ASCII bytes come out of `git diff --name-only` octal-escaped
(`"So\303\251.swift"`), which no unquoting here decodes. Set
`git config core.quotepath false` in the CI checkout so `git diff` emits raw
paths — one line, and every filename matches. When a non-empty scope matches no
analyzed file, deadwood prints a warning to stderr rather than silently
reporting nothing.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | the gate passed: no error-severity finding, so warnings and notes alone pass; with `--strict`, no warning or error. Also after `--write-baseline` |
| `1` | the gate failed on findings: an error-severity finding, or with `--strict` any warning or error — and nothing else |
| `64` | usage error: a bad argument, a path that does not exist, an unreadable `--only-from` file |
| `70` | nothing was analyzed: every file was skipped, and the report on stdout says which and why; or the run failed or was cancelled, and stdout is empty |
| `78` | invalid configuration, or a missing or malformed baseline |

`1` means findings *only*, so a step that posts a review comment on `1` will
not fire on a typo in the config file. Every rule defaults to warning, except
`preview-only` and `debug-only`, which default to note, so findings are always
reported, but only an `error` severity or `--strict` makes them fail the gate,
and a note never does. A cancelled run reports **no** findings
and exits `70` rather than looking clean: a whole-program analysis over a
partial corpus does not report less, it reports wrongly.

When every file is skipped (unreadable, not UTF-8, or over the 10 MiB cap),
deadwood still prints the report in the requested format — one
`deadwood/degraded-file` note per file in SARIF, whose invocation records
`"executionSuccessful": false` with an error notification — and then exits
`70`. A file whose analysis was only cut short, such as one function over the
dead-branch statement bound, does not count as skipped. A caller tells the
two `70`s apart by standard output: a report there means nothing could be
analyzed; empty means the run itself failed.

## License

MIT — see `LICENSE`.

[swift-syntax]: https://github.com/swiftlang/swift-syntax
[arcleak]: https://github.com/g-cqd/arcleak
[SwiftStaticAnalysis]: https://github.com/g-cqd/SwiftStaticAnalysis
