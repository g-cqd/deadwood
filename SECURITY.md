# Security Policy

## Scope and Trust Model

`deadwood` is a local, offline-first Swift static analysis tool.

- **Zero network access:** `deadwood` makes no outbound network requests and collects no telemetry.
- **No project code execution by default:** syntax analysis reads Swift source files, manifests, and Xcode project files as data without executing `Package.swift`, build plugins, or scripts. (Opt-in index auto-build runs `swift build` only when explicitly requested.)
- **Trust checks on loaded libraries and tools:** external toolchain libraries (`libIndexStore.dylib`) and `sourcekit-lsp` binaries are validated by `BinaryTrustChecker` (absolute canonical path, regular file, owned by `root` or the invoking user, not group- or world-writable).
- **Bounded input:** file reads enforce explicit byte caps (`BoundedFileReader`) before allocation, and directory snapshots refuse/skip symlinks and special files (`TreeSnapshot`).

## Supported Versions

Security fixes are released on the latest minor release on `main`. Always pin a fixed release tag and verify release checksums/signatures in CI.

## Reporting a Vulnerability

Report security concerns privately through [GitHub Security Advisories](https://github.com/g-cqd/deadwood/security/advisories/new) when private reporting is available. Do not include credentials or sensitive source code in public issues. If private reporting is unavailable, open a minimal issue requesting a private contact without disclosing exploit details.

## Response targets (best-effort, solo maintainer)

This project is maintained by a single developer on a best-effort basis; the targets below are realistic guidelines
rather than contractual SLAs:

| Milestone | Best-effort target |
| --- | --- |
| Private acknowledgement | Within **7–14 days** |
| Initial triage & severity confirmation | Within **30 days** |
| Fix & advisory — **Critical** | Within **30 days** (sooner when actively exploited) |
| Fix & advisory — **High** | Within **60–90 days** |
| Fix — **Medium / Low** | Next scheduled release, as time permits |

Security fixes in released versions are published with a GitHub Security Advisory (and CVE identifier where applicable)
and named in the release notes.
## Release Verification & Supply-Chain Integrity

All commits and release tags are signed with GPG key `9FE7C7E8522EE497` (fingerprint: `1BF1 901A 8C67 2E9B C12E 1B31 9FE7 C7E8 522E E497`).

Verify a downloaded release archive and tag before use:

```sh
# 1. Verify the signed Git tag
git tag -v <tag>

# 2. Verify the SHA-256 checksum
shasum -a 256 -c <archive>.sha256

# 3. Verify the GitHub SLSA build provenance attestation (requires gh CLI)
gh attestation verify <archive> --owner g-cqd
```
