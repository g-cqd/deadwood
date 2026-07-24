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
| `dead-branch` | on | branches whose condition provably folds to a constant |
| `referenced-only-by-tests` | on (fires only under `--production`) | declarations reachable with test roots but unreachable without them |
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
- **For a real "safe to delete" signal, use `--index-store` (macOS).** The
  compiler index resolves cross-file/cross-target/dynamic references and
  disambiguates same-named symbols the name graph conflates — it is the
  accuracy mode. On SwiftStaticAnalysis it cleared a name-conflation false
  positive and surfaced 58 genuinely dead declarations the syntax mode missed.
  It falls open to syntax mode when no index is present.
- **Keep the opt-in rules opt-in.** `unused-import` and `unused-public-api` are
  deliberately off by default: the import heuristic can't see extension or
  operator usage (it over-reports — hundreds of findings on a real corpus),
  and public API is a library's *surface*, not dead code. Enable them only on
  application targets, and treat them as review prompts, not deletion lists.
- **OS-discovered and preview entry points.** Types the system instantiates by
  conformance (`AppShortcutsProvider`, App Intents, Widgets) are rooted
  automatically. Declarations referenced *only* inside a top-level `#Preview`
  body are a known gap in syntax mode — exclude preview files
  (`"exclude": ["+Previews.swift"]`) or use `--index-store`, which sees them.
- **Accept intentional scaffolding** (author-your-own template stubs, debug
  helpers) with `// @dw:accept -- reason` so the decision is on record rather
  than re-flagged every run.

Bottom line: `deadwood analyze Sources Tests --index-store` on macOS is the
high-precision configuration; plain `deadwood analyze Sources` is the fast,
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

## Index-store mode (opt-in, macOS)

`deadwood analyze --index-store Sources` swaps the reachability oracle from
the name-level syntax graph to the compiler's **index store** (IndexStoreDB),
resolving each reference to the one USR the compiler recorded rather than to
every same-named declaration. This is the deferred M2: ~95% cross-module
precision. Everything else — root detection, the confidence model, member
collapse, suppression, the `unused-*` rules — is unchanged; only reachability
is resolved more precisely, so the finding set differs exactly where the
index is more accurate (it both *finds* dead code the name graph conflated
away and *clears* false positives it raised for cross-module references).

It needs a built index. deadwood discovers one under the project's
`.build/debug/index/store`, the new SwiftPM build system's `.build/out`
(versioned `vN/records`), or Xcode DerivedData:

```sh
swift build                                  # generate the index first
deadwood analyze --index-store Sources       # USR-precise reachability
deadwood analyze --index-store-path .build/out Sources   # explicit store
deadwood analyze --index-store-build Sources # run `swift build` if none found
```

Graceful by design: with no index found — or on Linux, where IndexStoreDB's
`libIndexStore.dylib` discovery is macOS-only — it prints a note to stderr
(`no index store found; falling back to syntax reachability — run
`swift build` to generate one`) and runs the ordinary syntax path. It never
hard-fails on a missing index. Without the flag, behavior is byte-identical
to the syntax analyzer.

Conservatism carries over from the syntax graph: declarations the index
cannot judge (unmapped), locals, in-corpus protocol requirements and their
witnesses, and base types of live subtypes are never flagged, so the index
oracle does not manufacture false positives from coverage gaps or dispatch.

## Experimental: embedding confidence

`deadwood analyze --experimental-embedding-confidence` (macOS) *annotates*
each finding with a semantic-anomaly score and changes nothing about which
findings fire. It embeds every flagged declaration's snippet with Apple's
system `NLContextualEmbedding` (zero third-party download; a deterministic
provider is the cross-platform fallback) and scores each as a kNN outlier
among its peers — a declaration whose code is a semantic outlier among the
other candidates is a softer or harder bet on being genuinely dead. The
score appears in the note (`embedding-confidence: N% anomaly [experimental]`).
Experimental and off by default; where NaturalLanguage is unavailable the
flag reports itself unavailable and leaves notes untouched.

## Confidence model

Every finding's note carries its confidence:

- **certain** — dataflow proofs (dead branches).
- **high / medium / low** — by *effective* visibility: private/fileprivate
  high, internal medium, package/public/open low (a member of a private
  type is effectively private).
- **Demotions** for dynamic-reference risk: a name appearing inside any
  string literal in the corpus (NSClassFromString-style lookup) forces low
  with a note; members of NSObject subclasses without `@objc` demote one
  step (selector machinery may reach them). Demoted findings still fire —
  risk lowers confidence, it never hides dead code.

## Facts cache

Corpus runs reuse per-file artifacts (facts, directives, dataflow findings)
through a fail-open cache keyed by content fingerprint (FNV-1a), salted by the
active dataflow passes, version-gated, and rebuilt from only the current run's
files (absent files are pruned). Detection always re-runs, so findings can
never go stale relative to rules or configuration.

On by default (default location `~/Library/Caches/deadwood/facts.json`;
`--cache-path` sets an explicit file; `--no-cache` disables it). The cache
serializes through [ADJSON](https://github.com/g-cqd/ADJSON)'s reflection-free
JSON fast path, and a full-hit re-analysis skips both the re-parse and the
redundant re-encode+write, so a warm run now beats a cold parse rather than
losing to it: on SwiftStaticAnalysis/Sources (156 files, release) a warm run
is ~263 ms against a ~282 ms cold `--no-cache` parse (0.93x). A corrupt or
mismatched cache behaves as empty.

## CLI

```sh
deadwood analyze Sources            # xcode-format diagnostics, exit 1 on errors
deadwood analyze --format sarif .   # SARIF 2.1.0 (also: --format json)
deadwood analyze --strict Sources   # exit 1 on any finding
deadwood analyze --production .     # split "only tests reach this" findings
deadwood analyze --no-cache .       # disable the (default-on) facts cache
deadwood analyze --index-store .    # USR-precise cross-module reachability (macOS; needs `swift build`)
deadwood rules                      # list rules; `rules <id>` explains one
```

## Accepting a finding

Directives use the `@` sigil with the `@dw:` or `@deadwood:` namespace:

```swift
// @dw:accept -- <why this finding is intentional>
// @dw:accept:this <rule|all> [-- reason]
// @dw:disable <rule|all> … // @dw:enable <rule|all>
```

Accepted analysis limits are cataloged in
`Tests/DeadwoodCoreTests/Fixtures/KnownGaps.md`, each pinned by a test.

## License

MIT — see `LICENSE`.

[swift-syntax]: https://github.com/swiftlang/swift-syntax
[arcleak]: https://github.com/g-cqd/arcleak
[SwiftStaticAnalysis]: https://github.com/g-cqd/SwiftStaticAnalysis
