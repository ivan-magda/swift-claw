#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

paths=(dependency_benchmark tests ../benchmark-core/benchmark_core)

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
