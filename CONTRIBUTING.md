# Contributing to deadwood

## Requirements

- Swift 6.4+ on macOS 15+ or Linux

## Workflow

1. Fork or branch from `main`.
2. Keep changes focused and backed by regression tests.
3. Run formatting and tests before opening a pull request:

```sh
swift format lint --strict --recursive Sources Tests Package.swift
swift test
```

## Standards

- Swift 6 language mode, strict concurrency, strict memory safety, and warnings as errors.
- No `DispatchQueue` / GCD in tool targets (`Scripts/no-gcd.sh` where present); prefer Swift concurrency and `Synchronization`.
- Keep documentation factual and synchronized with CLI flags, rules, and exit codes.
