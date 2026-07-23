#!/bin/bash
# Removal oracle: proves that what the analyzer flags is actually removable.
#
# Fixtures fence removable declarations between `// oracle:begin` and
# `// oracle:end` comment lines. For every Findings fixture with fences,
# the oracle deletes the fenced lines and typechecks the result — it MUST
# still typecheck (deleting a genuinely unused declaration cannot break the
# build). As a control, Clean fixtures may fence a REFERENCED declaration;
# deleting that MUST break the typecheck, proving the oracle can detect a
# bad removal at all.
#
# Not wired into CI yet; run locally.
set -euo pipefail
cd "$(dirname "$0")/.."

typecheck() {
  swiftly run swiftc -typecheck "$1" > /dev/null 2>&1
}

strip_fences() {
  awk '
    /oracle:begin/ { skip = 1; next }
    /oracle:end/   { skip = 0; next }
    skip == 0      { print }
  ' "$1" > "$2"
}

has_fences() {
  grep -q "oracle:begin" "$1"
}

scratch=$(mktemp -d "${TMPDIR:-/tmp}/deadwood-oracle.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

failures=0
findings_checked=0
controls_checked=0

for fixture in Tests/DeadwoodCoreTests/Fixtures/Findings/*.swift; do
  has_fences "$fixture" || continue
  base=$(basename "$fixture")
  findings_checked=$((findings_checked + 1))

  if ! typecheck "$fixture"; then
    echo "ORACLE FAIL: $base does not typecheck before removal (fixture is broken)"
    failures=$((failures + 1))
    continue
  fi

  stripped="$scratch/$base"
  strip_fences "$fixture" "$stripped"
  if typecheck "$stripped"; then
    echo "oracle: $base — flagged declarations removed, still typechecks"
  else
    echo "ORACLE FAIL: $base no longer typechecks after removing flagged declarations"
    failures=$((failures + 1))
  fi
done

for fixture in Tests/DeadwoodCoreTests/Fixtures/Clean/*.swift; do
  has_fences "$fixture" || continue
  base=$(basename "$fixture")
  controls_checked=$((controls_checked + 1))

  stripped="$scratch/control-$base"
  strip_fences "$fixture" "$stripped"
  if typecheck "$stripped"; then
    echo "ORACLE CONTROL FAIL: $base still typechecks after removing a referenced declaration"
    failures=$((failures + 1))
  else
    echo "oracle: control $base — removing a referenced declaration breaks the typecheck"
  fi
done

if [ "$findings_checked" -eq 0 ]; then
  echo "ORACLE FAIL: no Findings fixture carries oracle fences"
  failures=$((failures + 1))
fi
if [ "$controls_checked" -eq 0 ]; then
  echo "ORACLE FAIL: no Clean control fixture carries oracle fences"
  failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
  echo "removal-oracle: $failures failure(s)"
  exit 1
fi
echo "removal-oracle: all removals proven ($findings_checked fixture(s), $controls_checked control(s))"
