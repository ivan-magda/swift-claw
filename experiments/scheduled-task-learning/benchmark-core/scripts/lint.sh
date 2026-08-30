#!/usr/bin/env bash
# Lint gate for benchmark_core/, benchmark_learning/, and tests/.
# page-change/scripts/lint.sh also lints benchmark_core/, but it sees neither
# benchmark_learning/ nor tests/, so this gate covers all three itself.
# Reuses page-change's pinned dev toolchain rather than a second lockfile.
# Config: pyproject.toml.
#   scripts/lint.sh        check only (CI)
#   scripts/lint.sh --fix  auto-apply ruff's fixes
set -euo pipefail
cd "$(dirname "$0")/.."

paths=(benchmark_core benchmark_learning tests)

if [[ "${1:-}" == "--fix" ]]; then
  uv run --project ../page-change ruff format "${paths[@]}"
  uv run --project ../page-change ruff check --fix "${paths[@]}"
  echo "lint: applied fixes"
  exit 0
fi

uv run --project ../page-change ruff format --check "${paths[@]}"
uv run --project ../page-change ruff check "${paths[@]}"
uv run --project ../page-change mypy --config-file pyproject.toml "${paths[@]}"

echo "lint: ok"
