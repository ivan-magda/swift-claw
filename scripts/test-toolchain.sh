#!/usr/bin/env bash
# Acceptance checks for toolchain selection and identity using the installed compiler.
set -euo pipefail
repository_root=$(cd "$(dirname "$0")/.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/swift-claw-toolchain-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

fail() {
  printf 'toolchain workflow: %s\n' "$*" >&2
  exit 1
}

reset_pins() {
  cp "$repository_root/BuildTools/lint-versions.env" "$scratch/BuildTools/"
  cp "$repository_root/.swift-version" "$scratch/"
}

expect_rejection() {
  local scenario=$1 diagnostic=$2
  shift 2
  if "$@" > "$scratch/rejection.log" 2>&1; then
    fail "$scenario was accepted"
  fi
  if ! grep -Eq "^toolchain: $diagnostic" "$scratch/rejection.log"; then
    cat "$scratch/rejection.log" >&2
    fail "$scenario failed without identifying the mismatch"
  fi
}

# given: the installed compiler and repository pins describe the supported toolchain.
mkdir -p "$scratch/scripts" "$scratch/BuildTools"
cp "$repository_root/scripts/check-toolchain.sh" "$scratch/scripts/"
reset_pins
cd "$scratch"

# when / then: the real toolchain passes without overriding compiler output.
scripts/check-toolchain.sh

if [[ "$(uname -s)" == Darwin ]]; then
  # given: DEVELOPER_DIR and PATH select the same Xcode installation through a symlink.
  ln -s "$(xcode-select -p)" "$scratch/Developer"

  # when / then: the alternate spelling still identifies the supported bundled toolchain.
  DEVELOPER_DIR="$scratch/Developer" \
    PATH="$scratch/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH" \
    scripts/check-toolchain.sh
fi

# given: the toolchain selector disagrees with the shared pins.
printf '0.0\n' > .swift-version

# when / then: the disagreement is rejected before accepting the installed compiler.
expect_rejection 'conflicting pins' '\.swift-version .* disagree' scripts/check-toolchain.sh

# given: both selectors request a different compiler release.
printf 'CLAW_LINT_SWIFT_VERSION=0.0\n' >> BuildTools/lint-versions.env

# when / then: consistent pins still require the installed compiler version to match.
expect_rejection 'wrong Swift version' 'Swift .* required' scripts/check-toolchain.sh

case "$(uname -s)" in
  Darwin)
    compiler_build_pin=CLAW_LINT_SWIFT_MACOS_BUILD
    formatter_pin=CLAW_LINT_APPLE_FORMAT_MACOS_VERSION
    ;;
  Linux)
    compiler_build_pin=CLAW_LINT_SWIFT_LINUX_BUILD
    formatter_pin=CLAW_LINT_APPLE_FORMAT_LINUX_VERSION
    ;;
  *) fail 'supported test platforms are macOS and Linux' ;;
esac

# given: the release matches, but its compiler build identity does not.
reset_pins
printf '%s=unsupported-test-build\n' "$compiler_build_pin" >> BuildTools/lint-versions.env

# when / then: matching release numbers cannot hide an unexpected compiler build.
expect_rejection 'wrong compiler build' 'compiler identity mismatch' scripts/check-toolchain.sh

# given: the compiler matches, but the bundled formatter version does not.
reset_pins
printf '%s=unsupported-test-formatter\n' "$formatter_pin" >> BuildTools/lint-versions.env

# when / then: the shared preflight also rejects a formatter mismatch.
expect_rejection 'wrong formatter version' 'Apple swift-format .* required' scripts/check-toolchain.sh

if [[ "$(uname -s)" == Darwin ]]; then
  # given: the Xcode release matches while its build differs.
  reset_pins
  printf 'CLAW_XCODE_BUILD_VERSION=unsupported-test-build\n' >> BuildTools/lint-versions.env

  # when / then: compiler identity alone cannot authorize another Xcode build.
  expect_rejection 'wrong Xcode build' 'Xcode .* required' scripts/check-toolchain.sh

  # given: an environment override requests a non-default toolchain.
  reset_pins
  bundled_swift_directory=$(dirname "$(xcrun --toolchain XcodeDefault --find swift)")

  # when / then: selection policy rejects the override even with the expected Swift release.
  expect_rejection 'non-default toolchain' 'XcodeDefault required' \
    env TOOLCHAINS=swift PATH="$bundled_swift_directory:$PATH" scripts/check-toolchain.sh

  # given: a PATH wrapper forwards to the supported compiler and preserves its identity.
  mkdir "$scratch/standalone"
  printf '#!/bin/bash\nexec %q "$@"\n' "$(command -v swift)" > "$scratch/standalone/swift"
  chmod +x "$scratch/standalone/swift"

  # when / then: matching version output cannot authorize a different compiler path.
  expect_rejection 'non-bundled compiler path' '.*Xcode.*PATH' \
    env PATH="$scratch/standalone:$PATH" scripts/check-toolchain.sh
fi

printf 'toolchain workflow: ok (selection, version, compiler build, formatter)\n'
