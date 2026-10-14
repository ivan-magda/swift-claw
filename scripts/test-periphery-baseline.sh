#!/usr/bin/env bash
# Exercise the Periphery baseline gate on small scans, without Periphery or a build.
set -euo pipefail
repository_root=$(cd "$(dirname "$0")/.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/swift-claw-periphery-baseline-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

fail() {
  printf 'periphery baseline: %s\n' "$*" >&2
  exit 1
}

# The gate keeps its baseline beside itself, so it runs from a copy in the scratch directory.
mkdir -p "$scratch/scripts" "$scratch/BuildTools"
cp "$repository_root/scripts/check-periphery-baseline.py" "$scratch/scripts/"
log="$scratch/check.log"
check() {
  python3 -I "$scratch/scripts/check-periphery-baseline.py" "$@" > "$log" 2>&1
}
# Usage: finding LOCATION NAME USR. Prints one result of a Periphery JSON scan.
finding() {
  printf '{"location": "%s", "kind": "function.method.instance", "name": "%s", ' "$1" "$2"
  printf '"hints": ["unused"], "ids": ["%s"]}' "$3"
}
old_usr='s:3App3oldyyF'
helper_usr='s:8AppTests6helperyyF'
helper=$(finding Tests/AppTests/Helper.swift:2:8 'helper()' "$helper_usr")

# given: a backlog written from a scan that reports old() and a test helper.
printf '[%s, %s]\n' "$(finding Sources/App/Old.swift:3:8 'old()' "$old_usr")" "$helper" \
  > "$scratch/before.json"
check --write "$scratch/before.json" || {
  cat "$log" >&2
  fail '--write failed'
}
if grep -q "$helper_usr" "$scratch/BuildTools/periphery-baseline.txt"; then
  fail 'recorded a finding in test code as backlog'
fi

# when: old() moved, and both scans report a new declaration.
new=$(finding Sources/App/New.swift:5:8 'new()' 's:3App3newyyF')
printf '[%s, %s]\n' "$(finding Sources/App/Old.swift:9:8 'old()' "$old_usr")" "$new" \
  > "$scratch/all.json"
printf '[%s]\n' "$new" > "$scratch/prod.json"
if check "$scratch/all.json" "$scratch/prod.json"; then
  fail 'accepted a finding missing from the baseline'
fi

# then: the new declaration fails once, and the moved backlog entry still matches.
grep -q "^Sources/App/New.swift:5:8: error: unused: function.method.instance 'new()'" "$log" || {
  cat "$log" >&2
  fail 'did not name the new finding'
}
[[ $(grep -c 'New.swift' "$log") -eq 1 ]] || fail 'reported a declaration of both scans twice'
if grep -q 'Old.swift' "$log"; then
  fail 'reported a backlog finding whose code moved'
fi

# when: the code behind the backlog entry is gone, and only the test helper is reported.
printf '[%s]\n' "$helper" > "$scratch/after.json"

# then: the check passes, lists the test helper, and names the stale entry to shrink.
check "$scratch/after.json" || {
  cat "$log" >&2
  fail 'failed on a test-code finding or a stale baseline entry'
}
grep -q "^  Tests/AppTests/Helper.swift:2:8: unused: function.method.instance 'helper()'\$" \
  "$log" || {
  cat "$log" >&2
  fail 'did not list the test-code finding'
}
grep -q "^  $old_usr\$" "$log" || {
  cat "$log" >&2
  fail 'did not name the stale baseline entry'
}

printf 'periphery baseline: ok (new finding, moved backlog, test code, stale entry)\n'
