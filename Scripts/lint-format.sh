#!/bin/bash
# Format lint over first-party sources. Fixtures are excluded on purpose:
# they are resources reproducing third-party idioms verbatim.
set -euo pipefail
cd "$(dirname "$0")/.."

swift format lint --strict --recursive \
  Package.swift \
  Sources \
  Tests/DeadwoodCoreTests/*.swift
