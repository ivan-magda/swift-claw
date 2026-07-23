#!/bin/sh
set -eu
ENV_FILE="${CLAW_ENV_FILE:-$HOME/.swift-claw/clawd.env}"
# set -a: plain VAR=value lines must be exported to reach the exec'd clawd's environment.
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090  # env file path is runtime-configurable by design
  . "$ENV_FILE"
  set +a
fi
exec "${CLAWD_BIN:-/usr/local/bin/clawd}" run
