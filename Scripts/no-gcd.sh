#!/bin/bash
# Policy gate: GCD is prohibited in the implementation — Swift concurrency
# (structured tasks, actors) only. Fixtures may reproduce GCD idioms as test
# subject matter; those paths are deliberately not scanned.
set -euo pipefail
cd "$(dirname "$0")/.."

PATTERN='import Dispatch$|import Dispatch |DispatchQueue\.|DispatchQueue\(|DispatchSource\.make|DispatchSemaphore|DispatchGroup\(|DispatchWorkItem|dispatch_async|dispatch_sync'

if matches=$(grep -rnE "$PATTERN" Sources 2>/dev/null); then
  echo "FAIL: GCD usage in implementation code (use Swift concurrency instead):"
  echo "$matches"
  exit 1
fi
echo "no-gcd: implementation is GCD-free"
