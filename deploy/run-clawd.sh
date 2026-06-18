#!/bin/sh
set -eu
ENV_FILE="${CLAW_ENV_FILE:-$HOME/.swift-claw/clawd.env}"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
exec "${CLAWD_BIN:-/usr/local/bin/clawd}" run
