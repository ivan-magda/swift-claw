#!/usr/bin/env bash
# Build an index store and run Periphery twice: with tests, and with tests ignored.
#   bash periphery_scan.sh OUT_DIR
# Run from the package root. Writes OUT_DIR/all.json, OUT_DIR/prod.json and OUT_DIR/report.md.
#
# Periphery looks for the index store in .build/debug/index/store, but the default Swift Build
# backend writes it to .build/out, so a plain `periphery scan` fails with "index store path does
# not exist". This script builds into OUT_DIR/build, which leaves the working .build directory
# alone, and passes OUT_DIR/build/out to Periphery.
#
# The index store also holds the dependencies' sources, and Periphery 3 scans every file in it.
# The scans exclude OUT_DIR/build/checkouts: otherwise they report dependency code and drop our
# witnesses of dependency protocols, such as ArgumentParser's `configuration`. They write JSON
# because Periphery's CSV leaves the comma in `@available(*, unavailable)` unquoted.
set -euo pipefail

# The version triage.py's notes were checked against. Recheck them before changing it.
periphery_version=3.8.0

if [[ $# -ne 1 ]]; then
  echo "usage: bash periphery_scan.sh OUT_DIR" >&2
  exit 2
fi
command -v periphery >/dev/null || { echo "periphery not found (brew install periphery)" >&2; exit 2; }
installed_version=$(periphery version)
if [[ "$installed_version" != "$periphery_version" ]]; then
  echo "periphery $installed_version found; this script expects $periphery_version" >&2
  exit 2
fi

out=$(mkdir -p "$1" && cd "$1" && pwd -P)
script_dir=$(cd "$(dirname "$0")" && pwd -P)
index="$out/build/out"

echo "scan: building package and tests with an index store (several minutes)..." >&2
swift build --build-tests --scratch-path "$out/build" >"$out/build.log" 2>&1 ||
  { tail -20 "$out/build.log" >&2; echo "scan: build failed, see $out/build.log" >&2; exit 1; }
# The location is a Swift Build detail. Without this check, a move would surface only in all.err.
[[ -d "$index/v5/units" ]] ||
  { echo "scan: no index store in $index; find where swift build now writes it" >&2; exit 1; }

# Each scan also sends the project's line count to api.periphery.pro and, given a reply, prints
# a plan suggestion to stdout after the results. PERIPHERY_API_BASE_URL sends that request to a
# closed local port instead, and --quiet keeps any such message out of the JSON.
scan() {
  PERIPHERY_API_BASE_URL=http://127.0.0.1:9/v1 periphery scan --skip-build \
    --index-store-path "$index" --disable-update-check --quiet --relative-results \
    --format json --index-exclude "$out/build/checkouts/**" "$@"
}

echo "scan: Periphery, tests included..." >&2
scan >"$out/all.json" 2>"$out/all.err"
echo "scan: Periphery, tests and ClawTestSupport ignored..." >&2
scan --index-exclude 'Tests/**' --index-exclude 'Sources/ClawTestSupport/**' \
  >"$out/prod.json" 2>"$out/prod.err"

python3 -I "$script_dir/triage.py" "$out/all.json" "$out/prod.json" >"$out/report.md"
echo "scan: report written to $out/report.md" >&2
