#!/usr/bin/env bash
# Acceptance checks for the public formatter workflow; all sources live in a temporary repository.
set -euo pipefail
repository_root=$(cd "$(dirname "$0")/.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/swift-claw-lint-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

fail() {
  printf 'lint workflow: %s\n' "$*" >&2
  exit 1
}

# given: a maintained source file with violations that the canonical pipeline can correct.
mkdir -p "$scratch/scripts" "$scratch/Sources" "$scratch/Tests"
cp "$repository_root/scripts/lint.sh" "$repository_root/scripts/check-toolchain.sh" \
  "$scratch/scripts/"
cp "$repository_root/.swift-format" "$repository_root/.swiftlint.yml" \
  "$repository_root/.swift-version" "$scratch/"
cp "$repository_root/Tests/.swiftlint.yml" "$scratch/Tests/"
ln -s "$repository_root/BuildTools" "$scratch/BuildTools"
cp "$repository_root/BuildTools/Fixtures/style-pipeline.swift.txt" "$scratch/Sources/StyleFixture.swift"
cd "$scratch"
git init --quiet
git add .swiftlint.yml Tests/.swiftlint.yml Sources/StyleFixture.swift

# when: check encounters drift, then the user runs the advertised fix and check commands.
if scripts/lint.sh Sources/StyleFixture.swift > "$scratch/drift.log" 2>&1; then
  fail 'check accepted the unformatted fixture'
fi
grep -q 'canonical formatting differs' "$scratch/drift.log" || {
  cat "$scratch/drift.log" >&2
  fail 'check failed without identifying formatting drift'
}
scripts/lint.sh --fix Sources/StyleFixture.swift
scripts/lint.sh Sources/StyleFixture.swift
cp Sources/StyleFixture.swift "$scratch/first-pass.swift"
scripts/lint.sh --fix Sources/StyleFixture.swift

# then: the pipeline establishes the documented layout and a second fix changes no bytes.
cmp Sources/StyleFixture.swift "$scratch/first-pass.swift"
cmp Sources/StyleFixture.swift "$repository_root/BuildTools/Fixtures/style-pipeline.expected.swift.txt"

# given: a nested override changes an autocorrection for an unsaved test buffer.
printf '  - empty_count\n' >> Tests/.swiftlint.yml
cat > "$scratch/buffer.swift" <<'BUFFER'
import Testing
struct BufferFixture {
  func empty(_ values: [Int]) -> Bool { values.count == 0 }
}
BUFFER

# when: on-save formats the buffer with the same pipeline, without a file on disk.
scripts/lint.sh --format-stdin Tests/BufferFixture.swift < "$scratch/buffer.swift" \
  > "$scratch/formatted-buffer.swift"

# then: stdout is Swift only, the nested override applies, and no source is created.
[[ ! -e Tests/BufferFixture.swift ]] || fail 'stdin formatting created a source file'
head -n 1 "$scratch/formatted-buffer.swift" | grep -qx 'import Testing'
grep -q 'values.count == 0' "$scratch/formatted-buffer.swift"

# given: tools may be missing or have a different version before a requested fix.
mkdir "$scratch/missing-tools"
for executable in dirname swift git; do
  ln -s "$(command -v "$executable")" "$scratch/missing-tools/$executable"
done
cp Sources/StyleFixture.swift "$scratch/before-preflight.swift"

# when: SwiftLint cannot be resolved from PATH.
if PATH="$scratch/missing-tools" /bin/bash scripts/lint.sh --fix Sources/StyleFixture.swift \
  > "$scratch/missing.log" 2>&1; then
  fail 'fix succeeded without SwiftLint'
fi

# then: preflight fails clearly and leaves the source untouched.
grep -q 'swiftlint not found' "$scratch/missing.log"
cmp Sources/StyleFixture.swift "$scratch/before-preflight.swift"

# given: the installed linter reports a version outside the pinned toolchain.
mkdir "$scratch/wrong-version"
cat > "$scratch/wrong-version/swiftlint" <<'STUB'
#!/usr/bin/env bash
printf '0.0.0\n'
STUB
chmod +x "$scratch/wrong-version/swiftlint"

# when: a user asks that toolchain to fix a source file.
if PATH="$scratch/wrong-version:$PATH" scripts/lint.sh --fix Sources/StyleFixture.swift \
  > "$scratch/version.log" 2>&1; then
  fail 'fix accepted an unpinned SwiftLint version'
fi

# then: a version error replaces the success message and the source remains unchanged.
grep -q 'SwiftLint .* required' "$scratch/version.log"
cmp Sources/StyleFixture.swift "$scratch/before-preflight.swift"

# given: an unformatted source and a compiler with the right version but a different build.
mkdir "$scratch/wrong-compiler"
cat > "$scratch/wrong-compiler/swift" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == --version ]]; then
  printf 'Swift version %s (unsupported-test-build)\n' "$TEST_SWIFT_VERSION"
else
  exec "$TEST_SWIFT_EXECUTABLE" "$@"
fi
STUB
chmod +x "$scratch/wrong-compiler/swift"
cp "$repository_root/BuildTools/Fixtures/style-pipeline.swift.txt" Sources/StyleFixture.swift
cp Sources/StyleFixture.swift "$scratch/before-toolchain-preflight.swift"

# when: fix is requested with the unsupported compiler build.
if TEST_SWIFT_VERSION=$(cat .swift-version) TEST_SWIFT_EXECUTABLE=$(command -v swift) \
  PATH="$scratch/wrong-compiler:$PATH" scripts/lint.sh --fix Sources/StyleFixture.swift \
  > "$scratch/toolchain.log" 2>&1; then
  fail 'fix accepted an unsupported compiler build'
fi

# then: toolchain preflight fails before applying any formatter correction.
grep -q '^toolchain: compiler identity mismatch' "$scratch/toolchain.log"
cmp Sources/StyleFixture.swift "$scratch/before-toolchain-preflight.swift"

if [[ "$(uname -s)" == Darwin ]]; then
  # given: Swift matches, but Xcode/SDK selection does not.
  mkdir "$scratch/wrong-xcode"
  printf '#!/bin/sh\nprintf "unsupported-test-xcode\\n"\n' > "$scratch/wrong-xcode/xcodebuild"
  chmod +x "$scratch/wrong-xcode/xcodebuild"

  # when / then: the independent Xcode check rejects the fix without modifying source.
  if PATH="$scratch/wrong-xcode:$PATH" scripts/lint.sh --fix Sources/StyleFixture.swift \
    > "$scratch/xcode.log" 2>&1; then
    fail 'fix accepted an unsupported Xcode build'
  fi
  grep -q '^toolchain: Xcode .* required' "$scratch/xcode.log"
  cmp Sources/StyleFixture.swift "$scratch/before-toolchain-preflight.swift"
fi
printf 'lint workflow: ok (drift, one-pass fix, idempotence, buffer, missing tool, preflight)\n'
