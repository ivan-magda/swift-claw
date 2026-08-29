#!/usr/bin/env bash
# Runs the scheduled-learning replay-core unittest suite (stdlib only, no virtualenv needed).
set -euo pipefail
cd "$(dirname "$0")/.."

PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover -s tests -v
