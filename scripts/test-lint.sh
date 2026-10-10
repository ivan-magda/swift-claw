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

# given: the style repository becomes a package whose target never imports its dependency.
mkdir -p Sources/App Sources/Kit
printf 'struct App {}\n' > Sources/App/App.swift
printf 'public struct Kit {}\n' > Sources/Kit/Kit.swift
cat > Package.swift <<'MANIFEST'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Fixture",
  targets: [.target(name: "App", dependencies: ["Kit"]), .target(name: "Kit")]
)
MANIFEST
cp "$repository_root/scripts/check-dead-code.py" scripts/

# when: the whole-repository check runs.
if scripts/lint.sh > "$scratch/whole.log" 2>&1; then
  fail 'whole-repository check accepted an orphaned dependency'
fi

# then: lint ran its dead-code stage, which reported the dependency.
grep -q 'lint: Dead-code references' "$scratch/whole.log"
grep -q 'App declares Kit, but no file in the target imports it' "$scratch/whole.log"

# given: Python is missing from PATH.
mkdir "$scratch/no-python"
for executable in dirname swift swiftlint git; do
  ln -s "$(command -v "$executable")" "$scratch/no-python/$executable"
done

# when / then: the whole-repository check stops before any stage and names the missing tool.
if PATH="$scratch/no-python" /bin/bash scripts/lint.sh > "$scratch/no-python.log" 2>&1; then
  fail 'whole-repository check ran without Python'
fi
grep -q 'python3 not found' "$scratch/no-python.log"

# given: a separate package with the same orphaned dependency and a file nothing names.
dead_code="$scratch/dead-code"
mkdir -p "$dead_code/scripts" "$dead_code/BuildTools" "$dead_code/Sources/App" \
  "$dead_code/Sources/Kit" "$dead_code/docs"
cp "$repository_root/scripts/check-dead-code.py" "$dead_code/scripts/"
cp Package.swift "$dead_code/"
printf 'struct App {}\n' > "$dead_code/Sources/App/App.swift"
printf 'public struct Kit {}\n' > "$dead_code/Sources/Kit/Kit.swift"
printf 'diagram\n' > "$dead_code/docs/orphan-diagram.txt"
printf 'Run scripts/check-dead-code.py\n' > "$dead_code/README.md"
printf '.build/\n' > "$dead_code/.gitignore"
allowlist="$dead_code/BuildTools/dead-code-allowlist.txt"
check_dead_code() {
  (cd "$dead_code" && python3 -I scripts/check-dead-code.py) > "$scratch/dead-code.log" 2>&1
}
(cd "$dead_code" && git init --quiet && git add .)

# when / then: both findings fail with the allowlist line that would keep them.
if check_dead_code; then
  fail 'dead-code check accepted an orphaned dependency and an unreferenced file'
fi
grep -q "add 'dependency App Kit  # reason'" "$scratch/dead-code.log"
grep -q "add 'file docs/orphan-diagram.txt  # reason'" "$scratch/dead-code.log"

# when: both are kept with reasons, and an untracked scratch file appears.
printf 'dependency App Kit  # kept for the fixture\n' > "$allowlist"
printf 'file docs/orphan-diagram.txt  # kept for the fixture\n' >> "$allowlist"
printf 'scratch\n' > "$dead_code/docs/untracked-scratch.txt"

# then: the check passes; an untracked file is not a finding.
check_dead_code || {
  cat "$scratch/dead-code.log" >&2
  fail 'dead-code check rejected allowlisted findings or an untracked file'
}

# when / then: once App imports Kit, the dependency entry is stale.
printf 'import Kit\n' > "$dead_code/Sources/App/App.swift"
if check_dead_code; then
  fail 'dead-code check accepted a stale allowlist entry'
fi
grep -q "'dependency App Kit' no longer matches a finding" "$scratch/dead-code.log"

# when / then: an entry without a reason is a parse error.
printf 'file docs/orphan-diagram.txt\n' > "$allowlist"
if check_dead_code; then
  fail 'dead-code check accepted an allowlist entry without a reason'
fi
grep -q "expected 'file <path>  # reason'" "$scratch/dead-code.log"

# when / then: the same entry twice is rejected.
printf 'file docs/orphan-diagram.txt  # kept for the fixture\n' > "$allowlist"
printf 'file docs/orphan-diagram.txt  # kept twice\n' >> "$allowlist"
if check_dead_code; then
  fail 'dead-code check accepted a duplicate allowlist entry'
fi
grep -q 'duplicate entry' "$scratch/dead-code.log"

printf 'lint workflow: ok (drift, one-pass fix, idempotence, buffer, missing tool, preflight, '
printf 'dead-code references)\n'
