#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

PYTHONDONTWRITEBYTECODE=1 uv run python -B -m unittest discover -s tests -v
