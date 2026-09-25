#!/usr/bin/env bash
# Verify the Swift distribution shared by local lint, CI, and release builds.
set -euo pipefail
repository_root=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$repository_root"
# shellcheck source=BuildTools/lint-versions.env
source BuildTools/lint-versions.env

fail() {
  printf 'toolchain: %s\n' "$*" >&2
  exit 1
}

command -v swift >/dev/null 2>&1 || fail 'swift not found; see docs/CODE_STYLE.md'
swift_version=$(cat .swift-version)
swift_identity=$(swift --version 2>&1)
case "$(uname -s)" in
  Darwin)
    xcode_identity=$(xcodebuild -version)
    [[ "$xcode_identity" == "Xcode $CLAW_XCODE_VERSION"$'\n'"Build version $CLAW_XCODE_BUILD_VERSION" ]] ||
      fail "Xcode $CLAW_XCODE_VERSION ($CLAW_XCODE_BUILD_VERSION) required; found $xcode_identity"
    swift_build=$CLAW_LINT_SWIFT_MACOS_BUILD
    ;;
  Linux)
    swift_build="swift-${swift_version}-RELEASE"
    ;;
  *) fail 'supported toolchain platforms are macOS and Linux' ;;
esac
[[ "$swift_identity" == *"Swift version $swift_version ($swift_build)"* ]] ||
  fail "compiler identity mismatch; required Swift $swift_version ($swift_build); found $swift_identity"
printf 'toolchain: Swift %s (%s)\n' "$swift_version" "$swift_build" >&2
