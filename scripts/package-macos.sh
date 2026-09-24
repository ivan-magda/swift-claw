#!/usr/bin/env bash
# Bundle the Span compatibility runtime needed by macOS 15 release installations.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  printf 'Usage: %s <clawd-binary> <output-directory>\n' "$0" >&2
  exit 1
fi

binary=$1
output_directory=$2
runtime=libswiftCompatibilitySpan.dylib

mkdir -p "$output_directory"
install -m 755 "$binary" "$output_directory/clawd-macos-arm64"
xcrun --toolchain XcodeDefault swift-stdlib-tool --copy --scan-executable "$binary" \
  --platform macosx --destination "$output_directory"
install_name_tool -change "@rpath/$runtime" "@loader_path/$runtime" \
  "$output_directory/clawd-macos-arm64"
codesign --force --sign - "$output_directory/clawd-macos-arm64"

# An explicit sibling path makes the smoke test use the shipped library, not Xcode or the OS.
otool -L "$output_directory/clawd-macos-arm64" | grep -F "@loader_path/$runtime"
"$output_directory/clawd-macos-arm64" --version
(
  cd "$output_directory"
  shasum -a 256 clawd-macos-arm64 "$runtime" > clawd-macos-arm64.sha256
)
