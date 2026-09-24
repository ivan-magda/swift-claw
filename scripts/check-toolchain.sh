#!/usr/bin/env bash
# Verify the compiler and bundled formatter used by local development, CI, and releases.
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
[[ "$(cat .swift-version)" == "$CLAW_LINT_SWIFT_VERSION" ]] ||
  fail '.swift-version and BuildTools/lint-versions.env disagree'

swift_identity=$(swift --version 2>&1)
swift_version=$(printf '%s\n' "$swift_identity" |
  sed -nE 's/.*Swift version ([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p')
[[ "$swift_version" == "$CLAW_LINT_SWIFT_VERSION" ]] ||
  fail "Swift $CLAW_LINT_SWIFT_VERSION required; found $swift_version"

case "$(uname -s)" in
  Darwin)
    xcode_identity=$(xcodebuild -version)
    [[ "$xcode_identity" == "Xcode $CLAW_XCODE_VERSION"$'\n'"Build version $CLAW_XCODE_BUILD_VERSION" ]] ||
      fail "Xcode $CLAW_XCODE_VERSION ($CLAW_XCODE_BUILD_VERSION) required; found $xcode_identity"
    case "${TOOLCHAINS:-}" in
      ''|XcodeDefault|com.apple.dt.toolchain.XcodeDefault) ;;
      *) fail 'XcodeDefault required; unset TOOLCHAINS to use the bundled toolchain' ;;
    esac
    developer_directory=$(cd "$(xcode-select -p)" && pwd -P)
    bundled_directory="$developer_directory/Toolchains/XcodeDefault.xctoolchain/usr/bin"
    selected_directory=$(cd "$(dirname "$(xcrun --find swift)")" && pwd -P)
    [[ "$selected_directory" == "$bundled_directory" ]] ||
      fail 'XcodeDefault required; xcrun selected a different toolchain'
    swift_path=$(command -v swift)
    if [[ "$swift_path" != /usr/bin/swift ]]; then
      swift_directory=$(cd "$(dirname "$swift_path")" && pwd -P)
      [[ "$swift_directory" == "$bundled_directory" ]] ||
        fail 'use Xcode bundled Swift on PATH; see docs/CODE_STYLE.md'
    fi
    swift_build=$CLAW_LINT_SWIFT_MACOS_BUILD
    apple_format_version=$CLAW_LINT_APPLE_FORMAT_MACOS_VERSION
    installed_apple_format_version=$(xcrun --toolchain XcodeDefault swift-format --version)
    ;;
  Linux)
    swift_build=$CLAW_LINT_SWIFT_LINUX_BUILD
    apple_format_version=$CLAW_LINT_APPLE_FORMAT_LINUX_VERSION
    installed_apple_format_version=$(swift format --version)
    ;;
  *) fail 'supported toolchain platforms are macOS and Linux' ;;
esac
[[ "$swift_identity" == *"Swift version $CLAW_LINT_SWIFT_VERSION ($swift_build)"* ]] ||
  fail "compiler identity mismatch; required $swift_build; found $swift_identity"
[[ "$installed_apple_format_version" == "$apple_format_version" ]] ||
  fail "Apple swift-format $apple_format_version required; found $installed_apple_format_version"
printf 'toolchain: Swift %s (%s), swift-format %s\n' \
  "$swift_version" "$swift_build" "$installed_apple_format_version" >&2
