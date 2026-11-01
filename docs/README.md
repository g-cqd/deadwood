# Using deadwood

deadwood finds unused declarations and provably dead branches in Swift.

- [Getting started](getting-started.md): install, run, get good results, production mode, accepting a finding.
- [Rules](rules.md): the rules, the entry points that keep code alive, and the confidence of a finding.
- [Configuration](configuration.md): rules, exclusions, production mode.
- [Using it in CI](integration.md): pull-request gates, confidence thresholds, code made dead in other files.
- [Command line and reports](reports.md): options, the JSON report, exit codes, stability.
- [The index store](index-store.md): compiler-precise reachability (macOS).
- [Scoring findings by similarity](embeddings.md): the experimental score (macOS).
