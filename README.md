# deadwood

Unused- and dead-code detection for Swift: unreferenced declarations and provably dead branches.

Built on [swift-syntax], modeled on [arcleak]: source-level analysis (no build
required), fixture-gated precision, a comment directive DSL for auditable
acceptance, baselines for adoption on legacy code, and SARIF for code scanning.

**Status: engine landed.** The detection engine is lifted from
[SwiftStaticAnalysis]: declaration/reference collection over folded syntax
trees, entry-point root detection (@main, public API, @objc/IB, SwiftUI,
operators, protocol witnesses, raw-value enum cases), reachability analysis
across the corpus (direction-optimizing parallel BFS), and an SCCP
dead-branch pass per function body.

## Rules

| rule | default | finds |
| --- | --- | --- |
| `unused-function` | on | functions/methods unreachable from any entry point |
| `unused-type` | on | types nothing references (members collapse into the type) |
| `unused-property` | on | stored/computed properties with no reference |
| `unused-enum-case` | on | cases never constructed or matched (raw-value/Codable/CaseIterable enums exempt) |
| `dead-branch` | on | branches whose condition provably folds to a constant |
| `unused-import` | off | imports with no referenced symbol in the file (syntax-level heuristic) |
| `unused-public-api` | off | public declarations unreferenced inside the corpus (public API is a root otherwise) |

Two analysis shapes:

- `deadwood analyze <dirs>` — corpus mode: reachability from entry points
  across every file.
- `Analyzer.analyze(source:path:)` — single-file mode (what the fixture
  golden gate runs): only declarations *effectively private to the file*
  can be judged, because an internal declaration may be used from any other
  file of its module. Cross-file verdicts need corpus mode.

## CLI

```sh
deadwood analyze Sources            # xcode-format diagnostics, exit 1 on errors
deadwood analyze --format sarif .   # SARIF 2.1.0 (also: --format json)
deadwood analyze --strict Sources   # exit 1 on any finding
deadwood rules                      # list rules; `rules <id>` explains one
```

## Accepting a finding

Directives use the `@` sigil with the `@dw:` or `@deadwood:` namespace:

```swift
// @dw:accept -- <why this finding is intentional>
// @dw:accept:this <rule|all> [-- reason]
// @dw:disable <rule|all> … // @dw:enable <rule|all>
```

## License

MIT — see `LICENSE`.

[swift-syntax]: https://github.com/swiftlang/swift-syntax
[arcleak]: https://github.com/g-cqd/arcleak
[SwiftStaticAnalysis]: https://github.com/g-cqd/SwiftStaticAnalysis
