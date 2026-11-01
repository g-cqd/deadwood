# Getting started

deadwood reads Swift source and finds declarations nothing reaches and branches that cannot run. It needs no build to start;
an [index store](index-store.md) makes it more precise.

## Install

Download an archive from the [releases](https://github.com/g-cqd/deadwood/releases) (macOS arm64, Linux x86_64), or build with a
Swift 6.4 toolchain on macOS 15 or later, or Linux:

```sh
git clone https://github.com/g-cqd/deadwood.git && cd deadwood
swift build -c release
cp .build/release/deadwood /usr/local/bin/
```

## Run it

```sh
deadwood analyze Sources Tests          # Xcode-style diagnostics; exit 1 on errors
deadwood analyze --format sarif .       # also: --format json
deadwood analyze --strict Sources       # warnings fail too; notes never do
deadwood analyze --production .         # split out code that only tests reach
deadwood analyze --minimum-confidence high .
deadwood rules                          # list the rules; `rules <id>` explains one
```

Exit `0` means the gate passed and `1` means findings. `64`, `70`, `74` and `78` mean the run itself broke
([exit codes](https://github.com/g-cqd/analyzerkit/blob/main/docs/analyzer-contract.md#exit-codes)).

## Getting good results

What deadwood can say depends on what you point it at. A declaration used only from a file outside the set reads as unused.

- **Analyze the whole module, tests included:** `deadwood analyze Sources Tests`. Production code used only by tests is the largest
  source of false positives. Add `--production` to report it as its own finding, [`referenced-only-by-tests`](#production-mode),
  instead of hiding it.
- **For a "safe to delete" answer, use the index store** (macOS). The compiler resolves cross-file, cross-target and dynamic
  references and tells apart symbols that share a name. For an Xcode project it is the recommended setup:
  `deadwood analyze . --index-store-path <DerivedData>/<Project>-<hash>/Index.noindex/DataStore` after a build. For a package,
  `deadwood analyze Sources Tests --index-store`. See [index-store.md](index-store.md).
- **Plain `deadwood analyze Sources`** is the fast pass without setup. Review its findings; do not delete from them blindly.
- **Keep the opt-in rules opt-in.** `unused-import` cannot see extension or operator use, and `unused-public-api` flags a
  library's surface. Enable them on application targets and read them as prompts.
- **Accept scaffolding** you keep on purpose with `// @dw:accept -- reason`.

Entry points are found for you: `@main`, public API, `@objc`, Interface Builder, SwiftUI, App Intents, widgets, tests, and the
types that Info.plists, build settings, storyboards and xibs name. See [Rules](rules.md#entry-points). Point deadwood at
directories so it can find the project files.

## Production mode

`deadwood analyze --production Sources Tests` computes reachability twice, with and without test entry points. Declarations only
tests can reach get `referenced-only-by-tests`: not dead, since tests would break, but unused by production. Test files are those
the project calls tests (a `testTarget`, a test bundle), files that import a test framework, and otherwise paths under `Tests/` or
named `*Tests.swift`. `testsGlob` in the configuration replaces all of that with one pattern.

## Adopting it on existing code

```sh
deadwood analyze Sources Tests --write-baseline .deadwood-baseline.json
deadwood analyze Sources Tests --baseline .deadwood-baseline.json  # only new findings fail
```

See [baselines](https://github.com/g-cqd/analyzerkit/blob/main/docs/analyzer-contract.md#baselines-and-fingerprints).

## Accepting a finding

`@dw:` and `@deadwood:` are the same directive:

```swift
// @dw:accept -- kept for the template generator
// @dw:accept:this unused-function -- reason
// @dw:disable unused-type
// @dw:enable unused-type
```

Known limits are listed in `Tests/DeadwoodCoreTests/Fixtures/KnownGaps.md`, each pinned by a test.
