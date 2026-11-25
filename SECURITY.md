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
