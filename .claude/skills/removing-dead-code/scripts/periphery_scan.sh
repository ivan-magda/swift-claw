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
#
# Periphery reads .periphery.yml from the current directory, and BuildTools/lint-versions.env
# pins its version.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: bash periphery_scan.sh OUT_DIR" >&2
  exit 2
fi
# shellcheck source=BuildTools/lint-versions.env
source BuildTools/lint-versions.env
periphery_version=$CLAW_PERIPHERY_VERSION
command -v periphery >/dev/null || { echo "periphery not found (brew install periphery)" >&2; exit 2; }
installed_version=$(periphery version)
if [[ "$installed_version" != "$periphery_version" ]]; then
  cat >&2 <<EOF
periphery $installed_version found; this script expects $periphery_version, from homebrew-core or
the GitHub release that .github/workflows/dead-code.yml installs.
If it came from the old peripheryapp/periphery tap (it stops at 2.21.2), run in this order:
  brew untap peripheryapp/periphery
  brew uninstall --cask periphery
  brew install periphery
Uninstalling first fails: the tap's cask no longer loads ("Calling \`depends_on macos:
:catalina\` is disabled"). The untap succeeds with the cask installed, and the uninstall then
uses the installed copy.
EOF
  exit 2
fi

out=$(mkdir -p "$1" && cd "$1" && pwd -P)
script_dir=$(cd "$(dirname "$0")" && pwd -P)
index="$out/build/out"
# OUT_DIR is reused across runs, so a failed run must not leave the previous report behind.
rm -f "$out/report.md"

echo "scan: building package and tests with an index store (several minutes)..." >&2
swift build --build-tests --scratch-path "$out/build" >"$out/build.log" 2>&1 ||
  { tail -20 "$out/build.log" >&2; echo "scan: build failed, see $out/build.log" >&2; exit 1; }
# The location is a Swift Build detail, so name it if it moves.
[[ -d "$index/v5/units" ]] ||
  { echo "scan: no index store in $index; find where swift build now writes it" >&2; exit 1; }

# Each scan also sends the project's line count to api.periphery.pro and, given a reply, prints
# a plan suggestion to stdout after the results. PERIPHERY_API_BASE_URL sends that request to a
# closed local port instead, and --quiet keeps any such message out of the JSON.
# Usage: scan NAME [periphery options]. Writes OUT_DIR/NAME.json and OUT_DIR/NAME.err.
scan() {
  local name=$1
  shift
  PERIPHERY_API_BASE_URL=http://127.0.0.1:9/v1 periphery scan --skip-build \
    --index-store-path "$index" --disable-update-check --quiet --relative-results \
    --format json --index-exclude "$out/build/checkouts/**" "$@" \
    >"$out/$name.json" 2>"$out/$name.err" || {
      tail -20 "$out/$name.err" >&2
      echo "scan: Periphery failed, see $out/$name.err" >&2
      exit 1
    }
}

# Without tests, a public declaration that only another target's tests use looks redundantly
# public.
echo "scan: Periphery, tests included..." >&2
scan all
echo "scan: Periphery, tests and ClawTestSupport ignored..." >&2
scan prod --index-exclude 'Tests/**' --index-exclude 'Sources/ClawTestSupport/**' \
  --disable-redundant-public-analysis

python3 -I "$script_dir/triage.py" "$out/all.json" "$out/prod.json" >"$out/report.md"
echo "scan: report written to $out/report.md" >&2
