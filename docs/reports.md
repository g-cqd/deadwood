# Command line and reports

Shared options, exit codes and the report format are described in [how the analyzers behave](https://github.com/g-cqd/analyzerkit/blob/main/docs/analyzer-contract.md). This page lists what deadwood
adds.

## Options

| Option | |
| --- | --- |
| `--format xcode\|json\|sarif` | The output format (default `xcode`). |
| `--only PATH`, `--only-from FILE` | Report only these files; the whole corpus is still analyzed. |
| `--report-new-since BASELINE` | With `--only`, also report findings outside it that the baseline does not hold. |
| `--baseline FILE`, `--write-baseline FILE` | Drop accepted findings; record the current ones. |
| `--relative-to DIR` | Print paths relative to `DIR`; it also anchors fingerprints. |
| `--config FILE` | Read this configuration file. |
| `--cache-path DIR`, `--no-cache` | Move or disable the [cache](https://github.com/g-cqd/analyzerkit/blob/main/docs/analyzer-contract.md#the-facts-cache). |
| `--strict` | Warnings fail the gate too. |
| `--production` | Report code only tests reach as `referenced-only-by-tests`. |
| `--minimum-confidence LEVEL` | Report only `low`, `medium`, `high` or `certain` and above. Unscored findings are always reported. |
| `--include-regions`, `--exclude-regions` | `preview`, `debug`, `test`, `mock`, `generated`, `script` or `all`. |
| `--exclude-path PATTERN` | Leave matching files out of the report (not the corpus); repeatable. |
| `--rules IDS` | Run only these rules (comma-separated). |
| `--quiet`, `--verbose`, `--timings` | Say less or more on stderr; time each phase. |
| `--index-store`, `--index-store-path`, `--index-store-build` | [The index store](index-store.md). |
| `--experimental-embeddings confidence`, `--embedding-bundle` | [Scoring by similarity](embeddings.md). |

`--minimum-confidence` applies before `--baseline` and `--write-baseline`, so a baseline written with it holds only what the same
flag reports.

## The JSON report

The shared keys are in [the contract](https://github.com/g-cqd/analyzerkit/blob/main/docs/analyzer-contract.md#the-json-report). deadwood adds:

| Key | |
| --- | --- |
| `notes` | Informational notes, also printed on stderr. |
| `degradedFiles[].skipped` | `false` when only part of a file was skipped, such as one function over the dead-branch statement bound. |
| `findings[].confidence` | `certain`, `high`, `medium` or `low`; left out when the finding was not scored. |
| `findings[].note` | Begins with `confidence <level> — `. |

In SARIF the confidence is `properties.confidence`.

## Exit codes

The shared codes apply. Specifically for deadwood:

- `1`: only findings in the report count. One removed by `--baseline` or `--minimum-confidence`, out of scope, or suppressed does not;
  one promoted by `--report-new-since` does.
- `64` also covers `--report-new-since` without a scope, `--only-from -` with `-` as an input, and an `--only-from` file over 4 MiB.
- `70`: a file whose analysis was only cut short does not count as skipped.
- `78` also covers a configuration over 1 MiB or naming an unknown region.

## Stability

The `schemaVersion` is `1`. Within it, `deadwood analyze`, the options above, the exit codes and the JSON fields do not change
incompatibly; adding an option or a field is not a breaking change. Not covered: the experimental embedding options and
`DEADWOOD_EMBEDDING_BUNDLE`, the text of `deadwood rules`, and the `DeadwoodCore` library.
