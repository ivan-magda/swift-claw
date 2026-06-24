#!/usr/bin/env bash
# Lint gate: swift-format (layout) + SwiftLint (complexity/correctness/idiom).
# Config: .swift-format and .swiftlint.yml.
#   scripts/lint.sh        check only (CI / pre-commit)
#   scripts/lint.sh --fix  auto-apply both tools' fixes
#   STRICT=1 scripts/lint.sh   promote SwiftLint warnings to failures
set -euo pipefail
cd "$(dirname "$0")/.."

paths=(Sources Tests Package.swift)

if [[ "${1:-}" == "--fix" ]]; then
  swift format -i -r "${paths[@]}"
  command -v swiftlint >/dev/null 2>&1 && swiftlint --fix --quiet
  echo "lint: applied fixes"
  exit 0
fi

# swift-format is the source of truth for layout; any drift fails the gate.
swift format lint --strict -r "${paths[@]}"

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
