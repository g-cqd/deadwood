# Configuration

deadwood reads `.deadwood.json`, or a `"deadwood"` section of the shared `.swift-analyzers.json`
([how files are found and merged](https://github.com/g-cqd/analyzerkit/blob/main/docs/analyzer-contract.md#configuration)).

```json
{
  "rules": {
    "unused-import": { "enabled": true },
    "preview-only": { "severity": "note" }
  },
  "exclude": ["Generated/"],
  "production": true,
  "testsGlob": "**/Tests/**",
  "includeRegions": "preview"
}
```

| Key | |
| --- | --- |
| `rules` | `enabled` and `severity` (`note`, `warning`, `error`) per rule id. An unknown id is an error. |
| `exclude` | Paths to leave out of the **report**. They are still read, so what they use stays used. A pattern with `*`, `?` or `[` is a glob from the configuration's directory; any other is a substring. |
| `production` | Turn on [production mode](getting-started.md#production-mode). |
| `testsGlob` | One pattern that decides which files are tests in production mode. |
| `includeRegions`, `excludeRegions` | Shared; see [regions](https://github.com/g-cqd/analyzerkit/blob/main/docs/analyzer-contract.md#regions). |

Rules default to `warning`, except `preview-only` and `debug-only`, which are notes. No rule is an error by default.
