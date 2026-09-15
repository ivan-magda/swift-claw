#!/usr/bin/env bash
# Canonical Swift style gate. Diagnostics and timing go to stderr.
#   scripts/lint.sh [--fix] [--] [FILE.swift ...]
#   scripts/lint.sh --format-stdin FILE.swift < buffer > formatted-buffer
#   STRICT=1 scripts/lint.sh       also reject SwiftLint warnings
set -euo pipefail

repository_root=$(cd "$(dirname "$0")/.." && pwd -P)
invocation_directory=$PWD
cd "$repository_root"
# shellcheck source=BuildTools/lint-versions.env
source BuildTools/lint-versions.env

fail() {
  printf 'lint: %s\n' "$*" >&2
  exit 1
}

stage() {
  local label=$1
  shift
  printf 'lint: %s...\n' "$label" >&2
  local TIMEFORMAT="lint: $label (%3R s)"
  time "$@" >&2
}

mode=check
case "${1:-}" in
  --fix) mode=fix; shift ;;
  --format-stdin) mode=stdin; shift ;;
  --help|-h)
    sed -n '2,5s/^# //p' "$repository_root/scripts/lint.sh"
    exit 0
    ;;
esac
[[ "${1:-}" != -- ]] || shift
if [[ "$mode" == stdin && $# -ne 1 ]]; then
  fail '--format-stdin requires exactly one repository Swift file path'
fi

# Check every prerequisite before applying corrections or building SwiftFormat.
for executable in swift swiftlint git; do
  command -v "$executable" >/dev/null 2>&1 || fail "$executable not found; see docs/LOCAL_DEV.md"
done
swift_version=$(swift --version 2>&1 | sed -nE 's/.*Swift version ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')
[[ "$swift_version" == "$CLAW_LINT_SWIFT_VERSION" ]] ||
  fail "Swift $CLAW_LINT_SWIFT_VERSION required; found $swift_version"
case "$(uname -s)" in
  Darwin) apple_format_version=$CLAW_LINT_APPLE_FORMAT_MACOS_VERSION ;;
  Linux) apple_format_version=$CLAW_LINT_APPLE_FORMAT_LINUX_VERSION ;;
  *) fail 'supported lint platforms are macOS and Linux' ;;
esac
installed_apple_format_version=$(swift format --version)
[[ "$installed_apple_format_version" == "$apple_format_version" ]] ||
  fail "Apple swift-format $apple_format_version required; found $installed_apple_format_version"
[[ "$(swiftlint version)" == "$CLAW_LINT_SWIFTLINT_VERSION" ]] ||
  fail "SwiftLint $CLAW_LINT_SWIFTLINT_VERSION required"
[[ "$(cat .swift-version)" == "$CLAW_LINT_SWIFT_VERSION" ]] ||
  fail '.swift-version and BuildTools/lint-versions.env disagree'

files=()
if [[ $# -eq 0 ]]; then
  while IFS= read -r -d '' file; do
    files+=("$file")
  done < <(git ls-files -z --cached --others --exclude-standard -- \
    Sources Tests Package.swift BuildTools/Package.swift BuildTools/Sources | \
    while IFS= read -r -d '' file; do
      [[ "$file" != *.swift || ! -f "$file" ]] || printf '%s\0' "$file"
    done)
else
  for supplied in "$@"; do
    [[ "$supplied" != -* ]] || fail "unknown option: $supplied"
    if [[ "$supplied" != /* ]]; then
      supplied="$invocation_directory/$supplied"
    fi
    parent=$(cd "$(dirname "$supplied")" && pwd -P) || fail "invalid path: $supplied"
    absolute="$parent/$(basename "$supplied")"
    [[ "$absolute" == "$repository_root/"* ]] || fail "outside repository: $supplied"
    file=${absolute#"$repository_root/"}
    case "$file" in
      Sources/*.swift|Tests/*.swift|Package.swift|BuildTools/Package.swift|BuildTools/Sources/*.swift) ;;
      *) fail "outside maintained Swift source: $file" ;;
    esac
    files+=("$file")
  done
fi
[[ ${#files[@]} -gt 0 ]] || fail 'no Swift files selected'
for file in "${files[@]}"; do
  [[ ! -L "$file" ]] || fail "symbolic-link source is unsupported: $file"
  [[ "$mode" == stdin || -f "$file" ]] || fail "file not found: $file"
done

stage 'Prepare pinned SwiftFormat' swift build --package-path BuildTools -c release --product swiftformat
formatter_directory=$(swift build --package-path BuildTools -c release --show-bin-path)
formatter="$formatter_directory/swiftformat"
[[ "$("$formatter" --version)" == "$CLAW_LINT_SWIFTFORMAT_VERSION" ]] ||
  fail "SwiftFormat $CLAW_LINT_SWIFTFORMAT_VERSION required"

scratch=$(mktemp -d "${TMPDIR:-/tmp}/swift-claw-lint.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
original="$scratch/original"
formatted="$scratch/formatted"
mkdir -p "$original" "$formatted"
if [[ "$mode" == stdin ]]; then
  mkdir -p "$original/$(dirname "${files[0]}")"
  cat > "$original/${files[0]}"
else
  printf '%s\0' "${files[@]}" | tar -cf - --null -T - | tar -xf - -C "$original"
fi
cp -R "$original/." "$formatted"
# Preserve nested configuration lookup while formatting copies and editor buffers.
while IFS= read -r -d '' config; do
  mkdir -p "$formatted/$(dirname "$config")"
  cp "$config" "$formatted/$config"
done < <(git ls-files -z --cached --others --exclude-standard -- '*.swiftlint.yml')

format_copies() {
  cd "$formatted"
  stage "SwiftLint automatic fixes" swiftlint lint --fix --quiet "${files[@]}"
  stage "Apple layout" swift format format --in-place --parallel \
    --configuration "$repository_root/.swift-format" "${files[@]}"
  # Non-correctable Apple rules inspect Apple's intermediate layout.
  stage "Apple rules" swift format lint --strict --parallel \
    --configuration "$repository_root/.swift-format" "${files[@]}"
  stage "Targeted layout" "$formatter" \
    --config "$repository_root/BuildTools/conditional-bodies.swiftformat" \
    --quiet --cache ignore "${files[@]}"
  cd "$repository_root"
}
stage 'Canonical formatting' format_copies

if [[ "$mode" == stdin ]]; then
  cat "$formatted/${files[0]}"
  exit 0
fi

changed=0
for file in "${files[@]}"; do
  if ! cmp -s "$original/$file" "$formatted/$file"; then
    changed=$((changed + 1))
    if [[ "$mode" == fix ]]; then
      # Do not overwrite an editor save that arrived while the pipeline ran.
      cmp -s "$file" "$original/$file" || fail "changed during formatting: $file; retry"
      cat "$formatted/$file" > "$file"
    else
      printf '%s:1:1: error: canonical formatting differs; run scripts/lint.sh --fix\n' "$file" >&2
    fi
  fi
done

lint_arguments=(lint --quiet)
[[ "${STRICT:-0}" != 1 ]] || lint_arguments+=(--strict)
result=0
stage 'SwiftLint correctness and idiom' swiftlint "${lint_arguments[@]}" "${files[@]}" || result=1
if [[ "$mode" == check && "$changed" -gt 0 ]]; then
  result=1
fi
[[ "$result" -eq 0 ]] || exit "$result"
if [[ "$mode" == fix ]]; then
  printf 'lint: applied fixes to %s files\n' "$changed" >&2
fi
printf 'lint: ok\n' >&2
