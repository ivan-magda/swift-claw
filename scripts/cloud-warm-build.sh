#!/usr/bin/env bash
# SessionStart hook: in Claude Code cloud sessions, warm the package and lint builds in the
# background so later swift build/test and scripts/lint.sh runs are incremental. Elsewhere it
# does nothing. It never fails, so a broken toolchain cannot block a session from starting.
set -uo pipefail

[[ "${CLAUDE_CODE_REMOTE:-}" == true ]] || exit 0
command -v swift >/dev/null 2>&1 || exit 0
repository_root=$(cd "$(dirname "$0")/.." && pwd -P) || exit 0
cd "$repository_root" || exit 0
mkdir -p .build || exit 0

log_file=.build/cloud-warm-build.log
pid_file=.build/cloud-warm-build.pid
if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
  echo "Cloud warm-up build is still running; log: $log_file"
  exit 0
fi

# Plain flags, matching the documented gate, so later builds reuse this build's products.
warm_up='swift build --build-tests
swift build --package-path BuildTools -c release --product swiftformat'
# setsid detaches the build from the hook's process group; it is absent on macOS.
launcher=()
if command -v setsid >/dev/null 2>&1; then
  launcher=(setsid)
fi
nohup ${launcher[@]+"${launcher[@]}"} bash -c "$warm_up" >"$log_file" 2>&1 </dev/null &
echo "$!" >"$pid_file"
echo "Started a background warm-up build (swift build --build-tests, then the BuildTools" \
  "SwiftFormat build); log: $log_file. A swift build started meanwhile waits for it."
exit 0
