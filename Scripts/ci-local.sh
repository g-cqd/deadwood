#!/bin/bash
# The full local gate: everything CI checks, runnable before every push.
set -euo pipefail
cd "$(dirname "$0")/.."

swiftly run swift build --build-tests
swiftly run swift test
swiftly run swift run deadwood analyze Sources --strict
Scripts/lint-format.sh
Scripts/no-gcd.sh
echo "ci-local: all gates green"
