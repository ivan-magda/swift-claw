#!/usr/bin/env bash
# Lint gate: ruff (layout + idiom) + mypy --strict (types).
# Config: pyproject.toml.
#   scripts/lint.sh        check only (CI)
#   scripts/lint.sh --fix  auto-apply ruff's fixes
set -euo pipefail
cd "$(dirname "$0")/.."

paths=(page_benchmark tests ../benchmark-core/benchmark_core)

if [[ "${1:-}" == "--fix" ]]; then
  uv run ruff format "${paths[@]}"
  uv run ruff check --fix "${paths[@]}"
  echo "lint: applied fixes"
  exit 0
fi

uv run ruff format --check "${paths[@]}"
uv run ruff check "${paths[@]}"
uv run mypy
uv run mypy --config-file ../benchmark-core/pyproject.toml ../benchmark-core/benchmark_core

echo "lint: ok"
