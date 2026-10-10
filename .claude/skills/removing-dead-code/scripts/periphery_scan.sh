#!/usr/bin/env bash
# Build an index store and run Periphery twice: with tests, and with tests ignored.
#   bash periphery_scan.sh OUT_DIR
# Run from the package root. Writes OUT_DIR/all.csv, OUT_DIR/prod.csv and OUT_DIR/report.md.
#
# The default Swift Build backend writes no index store, so a plain `periphery scan` fails with
# "index store path does not exist". This script builds with the native build system into
# OUT_DIR/build, which leaves the working .build directory alone.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: bash periphery_scan.sh OUT_DIR" >&2
  exit 2
fi
command -v periphery >/dev/null || { echo "periphery not found (brew install periphery)" >&2; exit 2; }

out=$(mkdir -p "$1" && cd "$1" && pwd -P)
script_dir=$(cd "$(dirname "$0")" && pwd -P)
index="$out/index-store"

echo "scan: building package and tests with an index store (several minutes)..." >&2
swift build --build-tests --build-system native --scratch-path "$out/build" \
  -Xswiftc -index-store-path -Xswiftc "$index" >"$out/build.log" 2>&1 ||
  { tail -20 "$out/build.log" >&2; echo "scan: build failed, see $out/build.log" >&2; exit 1; }

scan() {
  periphery scan --skip-build --index-store-path "$index" --disable-update-check \
    --relative-results --format csv "$@"
}

echo "scan: Periphery, tests included..." >&2
scan >"$out/all.csv" 2>"$out/all.err"
echo "scan: Periphery, tests and ClawTestSupport ignored..." >&2
scan --index-exclude 'Tests/**' --index-exclude 'Sources/ClawTestSupport/**' \
  >"$out/prod.csv" 2>"$out/prod.err"

python3 -I "$script_dir/triage.py" "$out/all.csv" "$out/prod.csv" >"$out/report.md"
echo "scan: report written to $out/report.md" >&2
