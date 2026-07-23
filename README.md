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

## Production mode

`deadwood analyze --production Sources Tests` computes reachability twice
over the same graph: once with test entry points (test methods, XCTestCase
subclasses, @Suite types, tests-glob files) and once without. Declarations
only tests can reach get the `referenced-only-by-tests` rule — not dead
(the tests would break), but nothing in production uses them. Genuinely
unreachable declarations keep their normal rules, and the rule never points
into test code itself. `testsGlob` in `.deadwood.json` overrides the
built-in `**/Tests/**` + `**/*Tests.swift` heuristics.

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

Corpus runs can reuse per-file artifacts (facts, directives, dataflow
findings) through a fail-open cache keyed by content fingerprint (FNV-1a),
salted by the active dataflow passes, version-gated, and rebuilt from only
the current run's files (absent files are pruned). Detection always
re-runs, so findings can never go stale relative to rules or configuration.
Opt-in (`--cache`, default location `~/Library/Caches/deadwood/facts.json`;
`--cache-path` overrides and implies `--cache`; `--no-cache` wins) because
on corpora of small files re-parsing beats the cache's JSON round-trip — it
pays off when per-file extraction dominates. A corrupt or mismatched cache
behaves as empty.

## CLI

```sh
deadwood analyze Sources            # xcode-format diagnostics, exit 1 on errors
deadwood analyze --format sarif .   # SARIF 2.1.0 (also: --format json)
deadwood analyze --strict Sources   # exit 1 on any finding
deadwood analyze --production .     # split "only tests reach this" findings
deadwood analyze --cache .          # reuse per-file facts across runs
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
