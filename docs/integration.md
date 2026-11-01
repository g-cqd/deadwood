# Using deadwood in CI

## As a pull-request gate

Analyze the whole repository and scope the report to the change. Handing deadwood only the changed files makes live code look
dead ([why](https://github.com/g-cqd/analyzerkit/blob/main/docs/analyzer-contract.md#scoping-a-report-to-some-files)).

```sh
git diff --name-only origin/main... -- '*.swift' > changed.txt
deadwood analyze . --only-from changed.txt --baseline .deadwood-baseline.json --strict
```

For code scanning, add `--format sarif --relative-to .` and upload the result ([SARIF](https://github.com/g-cqd/analyzerkit/blob/main/docs/analyzer-contract.md#sarif)). A composite GitHub Action
(`action.yml`) builds deadwood, analyzes, and uploads it.

## Only new findings, above a confidence

Write the baseline on the base branch (unscoped), then read it on the pull request. Use the same `--relative-to` and
`--minimum-confidence` in both runs, or a lower level on the baseline run:

```sh
# on the base branch
deadwood analyze Sources Tests --relative-to . --minimum-confidence high --write-baseline base.json

# on the pull request
git diff --name-only origin/main... -- '*.swift' > changed.txt
deadwood analyze Sources Tests --relative-to . --minimum-confidence high \
    --baseline base.json --only-from changed.txt --strict
```

Findings are scoped to the changed files, then filtered by `--minimum-confidence`, then matched against the baseline. Only what
remains decides the exit code. Without `--strict`, only errors fail, and no rule is an error by default.

## Code the change left dead in other files

A pull request can remove the last use of a declaration in an untouched file. `--only` hides that finding.
`--report-new-since` reports it:

```sh
deadwood analyze . --relative-to . --write-baseline base.json                      # on the base branch
deadwood analyze . --relative-to . --only-from changed.txt --report-new-since base.json --strict
```

- A finding outside the scope that the baseline does not hold moves into the report and counts toward exit `1`. The run notes
  how many, on stderr and in the JSON `notes`.
- It needs `--only` or `--only-from`, and cannot be combined with `--write-baseline`. A missing or malformed baseline exits `78`.
- The usual "scope matches no file" warning is not printed, so a change that only deletes a file can name it.
- Write the baseline with the lowest `--minimum-confidence` any reading run will use. A baseline written without the flag is safe
  for every level; a baseline written with a higher level makes everything below it look new.
- A finding whose message changed is new. When a change deletes one of the dead users a transitive finding names, the message
  changes from "only used by dead code" to "never referenced".
