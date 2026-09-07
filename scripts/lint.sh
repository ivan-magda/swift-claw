#!/usr/bin/env bash
# Lint gate: swift-format + targeted SwiftFormat rules + SwiftLint.
# Config: .swift-format, BuildTools/guard-bodies.swiftformat, and .swiftlint.yml.
#   scripts/lint.sh        check only (CI / pre-commit)
#   scripts/lint.sh --fix  auto-apply all formatter and linter fixes
#   STRICT=1 scripts/lint.sh   promote SwiftLint warnings to failures
set -euo pipefail
cd "$(dirname "$0")/.."

paths=(Sources Tests Package.swift BuildTools/Package.swift BuildTools/Sources)
repository_root=$PWD
guard_format_paths=(
  "$repository_root/Sources"
  "$repository_root/Tests"
  "$repository_root/Package.swift"
  "$repository_root/BuildTools/Package.swift"
  "$repository_root/BuildTools/Sources"
)

run_guard_formatter() {
  swift run --package-path BuildTools swiftformat \
    --config "$repository_root/BuildTools/guard-bodies.swiftformat" \
    "$@" \
    "${guard_format_paths[@]}"
}

if [[ "${1:-}" == "--fix" ]]; then
  run_guard_formatter
  swift format -i -r "${paths[@]}"
  command -v swiftlint >/dev/null 2>&1 && swiftlint --fix --quiet
  echo "lint: applied fixes"
  exit 0
fi

# Apple swift-format owns general layout; the targeted pass fills its guard-body gap.
swift format lint --strict -r "${paths[@]}"
run_guard_formatter --lint

if ! command -v swiftlint >/dev/null 2>&1; then
  echo "lint: swiftlint not found — install with 'brew install swiftlint'" >&2
  exit 1
fi

# STRICT=1 fails on warnings too. Off by default while the intentional force-unwrap
# warnings stand; flip it once those are resolved.
if [[ "${STRICT:-0}" == "1" ]]; then
  swiftlint lint --strict --quiet
else
  swiftlint lint --quiet
fi

echo "lint: ok"
