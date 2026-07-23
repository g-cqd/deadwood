# Known gaps

Accepted analysis misses, each deliberate and pinned by a test so a change
in behavior — better or worse — fails loudly. The bias is uniform: when the
analysis cannot know, it stays SILENT (false-negative direction) or demotes
confidence; it never invents findings.

## Name-collision over-connection (false-negative direction)

Edges are name-level: every reference inside a declaration's line range
connects to every same-named declaration in the corpus. Two unrelated
`reset()` methods keep each other alive; a dead method named like a live
one is missed. This over-approximation is the price of running without a
build (no semantic index), and it errs exclusively toward false negatives.

- Pinned by: `EngineWiringTests` (corpus-mode reachability across files),
  `ReachabilityGraphTests` (edge semantics), `PrecisionTests`
  (name-producing constructs: `#selector`, key paths, shorthand cases).
- Sharper future: an index-store backend could resolve references
  semantically; the graph already runs on dense indices, so only edge
  computation would change.

## Single-file mode judges only the file-private surface

`analyze(source:path:)` roots every declaration that is effectively visible
outside the file (`internal` and wider): one file alone cannot prove such a
declaration unused, because any other file of the module may use it.
Verdicts are limited to effectively-private declarations; everything else
needs corpus mode.

- Pinned by: `EngineWiringTests/internalOutOfSingleFileScope`,
  `SimpleModeTests` (the `treatVisibleOutsideFileAsRoot` matrix).

## No cross-module visibility

The corpus is exactly the analyzed file set. Public/open declarations are
roots by default because callers outside the corpus are invisible; the
opt-in `unused-public-api` rule flips that assumption for application
targets. `@_exported import` is treated as usage of the imported module.
There is no resolution INTO other modules: a symbol shadowing a dependency's
symbol over-connects (same FN direction as name collisions).

- Pinned by: `OptInRuleTests` (`unused-public-api` both directions,
  `@_exported` never flagged), `RootDetectionTests/publicAsRoot`.

## Property-wrapper contracts are a finite catalog (@Transient analogs)

Wrappers whose synthesized accessors imply usage (`@State`, `@Published`,
...) come from a fixed catalog (`PropertyWrapperKind.impliesUsage`).
Unknown third-party wrappers do NOT imply usage — a `@Transient`-analog
whose machinery reads the property invisibly can surface as a false
positive on the wrapped property; accept it with a directive or extend the
catalog. The compiler-contract names `wrappedValue`/`projectedValue` are
always rooted, so writing a custom wrapper never flags its own contract.

- Pinned by: `RootDetectionTests/swiftUIPropertyWrapperAsRoot`,
  `Fixtures/Clean/PropertyWrapperContract.swift`,
  `Fixtures/Clean/SwiftUIFalsePositives.swift`.

## Dynamic references are demoted, never resolved

`NSClassFromString("LegacyMigrator")`, selector strings, and reflection by
name cannot be proven statically. The SCARF token set (identifier-shaped
tokens inside string literals) demotes matching findings to low confidence
with a note — the finding still fires, because suppressing on a substring
match would let any comment-adjacent string hide real dead code.

- Pinned by: `Fixtures/Findings/StringLiteralDemotion.swift` (fires,
  demoted) and `ConfidenceTests/stringLiteralNameDemotes`.

## Member-access reads and writes are indistinguishable

`object.property = x` and `let y = object.property` both surface as member
accesses at the syntax level. `assign-only-property` therefore treats any
non-write reference context as a potential read and only judges self-shaped
code (`property = x` inside the owning type) — conservative, opt-in.

- Pinned by: `OptInRuleTests/assignOnlyStaysSilentWhenPropertyIsRead`.
