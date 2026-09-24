#!/bin/sh
# Run only in a fresh Linux Docker container; the real installer uses its disposable home.
set -eu

fail() { printf 'installer workflow: %s\n' "$*" >&2; exit 1; }

[ "$(/usr/bin/uname -s)" = Linux ] && [ -f /.dockerenv ] \
  || fail 'run in a disposable Linux Docker container'
[ -n "${HOME:-}" ] && [ ! -e "$HOME/.swift-claw" ] && [ ! -L "$HOME/.swift-claw" ] \
  || fail 'the container must have no existing ~/.swift-claw'

repository_root=$(cd "$(dirname "$0")/.." && pwd -P)
scratch=$(mktemp -d "$HOME/.swift-claw-install-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
fixture_assets="$scratch/assets"
export fixture_assets
mkdir "$fixture_assets" "$scratch/tools"

# Downloads and host/service probes are external seams; installation and hashing remain real.
cat > "$scratch/tools/curl" <<'STUB'
#!/bin/sh
set -eu
destination=
url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) destination=$2; shift 2 ;;
    https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
[ -n "$destination" ] && [ -n "$url" ]
cp "$fixture_assets/${url##*/}" "$destination"
STUB
cat > "$scratch/tools/uname" <<'STUB'
#!/bin/sh
case "$1" in
  -s) printf 'Darwin\n' ;;
  -m) printf 'arm64\n' ;;
  *) exit 1 ;;
esac
STUB
printf '#!/bin/sh\nprintf "15.0\\n"\n' > "$scratch/tools/sw_vers"
printf '#!/bin/sh\nprintf "0\\n"\n' > "$scratch/tools/sysctl"
printf '#!/bin/sh\nexit 1\n' > "$scratch/tools/gh"
cat > "$scratch/tools/launchctl" <<'STUB'
#!/bin/sh
case "$1" in
  print) exit 1 ;;
  bootout) exit 0 ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$scratch/tools/"*
export PATH="$scratch/tools:$PATH"
export CLAWD_NO_MODIFY_PATH=1
export CLAWD_VERSION=v99.0.0

cp "$repository_root/.env.example" "$fixture_assets/clawd.env.example"
cp "$repository_root/deploy/run-clawd.sh" \
  "$repository_root/deploy/com.ivanmagda.swift-claw.plist" "$fixture_assets/"
cat > "$fixture_assets/clawd-macos-arm64" <<'BINARY'
#!/bin/sh
[ -f "$(dirname "$0")/libswiftCompatibilitySpan.dylib" ] || exit 1
printf 'fixture-new\n'
BINARY
printf 'fixture-runtime-1\n' > "$fixture_assets/libswiftCompatibilitySpan.dylib"

write_manifest() {
  (cd "$fixture_assets" && sha256sum clawd-macos-arm64 clawd.env.example run-clawd.sh \
    com.ivanmagda.swift-claw.plist "$@" > SHA256SUMS)
}

install_release() {
  if ! sh "$repository_root/install.sh" > "$scratch/install.log" 2>&1; then
    cat "$scratch/install.log" >&2
    fail 'valid release failed to install'
  fi
}

expect_rejected_upgrade() {
  if sh "$repository_root/install.sh" > "$scratch/install.log" 2>&1; then
    fail "$1 was installed"
  fi
  cmp "$scratch/working-clawd" "$HOME/.swift-claw/bin/clawd"
  cmp "$scratch/working-runtime" "$HOME/.swift-claw/bin/libswiftCompatibilitySpan.dylib"
  [ "$("$HOME/.swift-claw/bin/clawd" --version)" = fixture-new ]
}

# given / when: a macOS release needs its adjacent runtime, including during the smoke check.
write_manifest libswiftCompatibilitySpan.dylib
install_release

# then: the installed bundle runs, and re-installation preserves owner configuration and data.
[ "$("$HOME/.swift-claw/bin/clawd" --version)" = fixture-new ]
printf 'owner-config\n' > "$HOME/.swift-claw/clawd.env"
printf 'owner-data\n' > "$HOME/.swift-claw/claw.sqlite"
cp "$HOME/.swift-claw/clawd.env" "$scratch/owner-config"
cp "$HOME/.swift-claw/claw.sqlite" "$scratch/owner-data"
install_release
cmp "$fixture_assets/libswiftCompatibilitySpan.dylib" \
  "$HOME/.swift-claw/bin/libswiftCompatibilitySpan.dylib"
cp "$HOME/.swift-claw/bin/clawd" "$scratch/working-clawd"
cp "$HOME/.swift-claw/bin/libswiftCompatibilitySpan.dylib" "$scratch/working-runtime"
cmp "$scratch/owner-config" "$HOME/.swift-claw/clawd.env"
cmp "$scratch/owner-data" "$HOME/.swift-claw/claw.sqlite"

# given / when / then: a corrupted sidecar is rejected before changing the working bundle.
sed 's/fixture-new/fixture-upgrade/' "$scratch/working-clawd" > "$fixture_assets/clawd-macos-arm64"
write_manifest libswiftCompatibilitySpan.dylib
printf 'corrupted-runtime\n' > "$fixture_assets/libswiftCompatibilitySpan.dylib"
expect_rejected_upgrade 'a runtime with a mismatched checksum'

# given / when / then: valid checksums do not permit a failing candidate to replace either file.
printf '#!/bin/sh\nexit 1\n' > "$fixture_assets/clawd-macos-arm64"
printf 'fixture-runtime-2\n' > "$fixture_assets/libswiftCompatibilitySpan.dylib"
write_manifest libswiftCompatibilitySpan.dylib
expect_rejected_upgrade 'a binary that fails its smoke check'

# given / when: a pinned legacy release has no runtime asset in its manifest or downloads.
printf '#!/bin/sh\nprintf "fixture-legacy\\n"\n' > "$fixture_assets/clawd-macos-arm64"
rm "$fixture_assets/libswiftCompatibilitySpan.dylib"
write_manifest
install_release

# then: the old binary runs and the obsolete owned runtime is removed.
[ "$("$HOME/.swift-claw/bin/clawd" --version)" = fixture-legacy ]
[ ! -e "$HOME/.swift-claw/bin/libswiftCompatibilitySpan.dylib" ]

# given / when: a complete runtime bundle is installed again and then uninstalled publicly.
cp "$scratch/working-clawd" "$fixture_assets/clawd-macos-arm64"
cp "$scratch/working-runtime" "$fixture_assets/libswiftCompatibilitySpan.dylib"
write_manifest libswiftCompatibilitySpan.dylib
install_release
sh "$repository_root/install.sh" --uninstall > "$scratch/uninstall.log" 2>&1

# then: no executable bundle or service remains, while owner state is preserved.
[ ! -e "$HOME/.swift-claw/bin" ]
[ ! -e "$HOME/Library/LaunchAgents/com.ivanmagda.swift-claw.plist" ]
cmp "$scratch/owner-config" "$HOME/.swift-claw/clawd.env"
cmp "$scratch/owner-data" "$HOME/.swift-claw/claw.sqlite"
printf 'installer workflow: ok (runtime, repeat, checksum, preflight, legacy, uninstall)\n'
