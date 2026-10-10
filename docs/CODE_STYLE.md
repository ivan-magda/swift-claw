# Swift code style

swift-claw follows the [Google Swift Style Guide](https://google.github.io/swift/), including
its reference to the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/).
The adopted revision, explicit local exceptions, and tool ownership are normative in
[ARCHITECTURE.md §19.2](ARCHITECTURE.md#192-source-formatting-and-lint).

## Local rules and exceptions

- Nonempty conditional/loop statements and closure bodies are multiline; inline `if` expressions
  remain allowed.
- Nonempty `do` and `catch` bodies are multiline; review this manually.
- Switch case bodies start on their own line, including single-statement bodies.
- Nonempty type, extension, function, initializer, subscript, and computed-property bodies are
  multiline. Empty bodies may remain `{}`.
- Group private helpers in `private extension` blocks with an immediately preceding
  `// MARK: - <Group Name>`. Put other access modifiers on members.
- Structure tests with `// given`, `// when`, and `// then`.
- Keep documentation summaries concise, normally one or two lines; add necessary contract
  details and tags. Obvious declarations need no documentation boilerplate. Ordinary comments
  explain enduring constraints the code cannot express; change rationale belongs in the commit
  or PR. Never cite a bare `§N`: explain the constraint, or use `ARCHITECTURE.md §N` only where
  the code would otherwise read as a bug. The code map in architecture §3.1 points from docs to code.
- The 100-character gate exempts comments and URLs. An intact opaque literal needs a reasoned
  single-line suppression, as specified in the architecture.
- Preserve the `ClawCore` seam/error placement when considering Google's nesting preference.
- The pinned Subprocess SDK's `Environment.Key(stringLiteral:)` is a narrow dynamic-key
  exception until that API exposes a suitable public nonfailable alternative.

## Readability and control flow

These review recommendations apply the existing naming, early-exit, and formatting rules.
Use them where they clarify intent; they are not blanket rewrites or new formatter exceptions.

### Separate operations from checks

Prefer a named result when a condition contains a multiline call, a closure, or an operation
whose effects are hard to distinguish from the check. Keep the result and its guard together:

```swift
let scope = await presentations?.stoppableRun(
  chatID: stop.chatID,
  threadID: stop.messageThreadID,
  draftID: stop.draftID
)
guard let scope else {
  return .skipped
}
```

Keep simple lookups such as `guard let entry = entriesByRunID[runID] else` compact.
Separate checks when they represent distinct failure cases, such as a missing run and a run
that cannot be cancelled. Preserve short-circuit evaluation: do not move an operation ahead of
an earlier condition that previously prevented it from running.

### Name values by their role

Prefer names that explain what a result represents: `feedbackOutcome`, `confirmationOutcome`,
and `resolvedApprovalIDs` rather than `consumed` or `resolved`. `result` remains appropriate
when the surrounding code makes its role clear; longer names are not inherently better.

Distinguish time instants from durations. Names such as `startedAt` and `acceptedAt` identify
instants; `acceptanceMilliseconds` identifies a duration and its unit.

### Separate logical steps

Use a blank line between phases such as lookup, state mutation, result handling, and delivery.
Keep closely related statements together, including a value's initialization and its guard.
Avoid adding a blank line after every statement or a comment that only labels an obvious step.

### Lay out multiline method chains by stage

For a chain that already spans multiple lines, prefer one chained call per continuation line.
Keep nonempty closure bodies multiline:

```swift
let predecessors = operations.values
  .filter { $0.runID == runID }
  .map(\.task)
```

Introduce intermediate variables when their names explain a domain concept or separate a
meaningful operation. Do not split a clear chain into locals solely to avoid chaining. Use
named closure parameters when their roles need explanation; `$0` is suitable for a simple,
unambiguous transformation or predicate.

### Choose a readable conditional value

A ternary expression works well for a short choice between values. Prefer a multiline `if`
expression when a branch performs an operation whose execution or failure behavior deserves
attention, such as allocating a draft identity:

```swift
let draftID: Int64? =
  if draftsEnabled(for: scope) {
    try? draftIDs.nextID()
  } else {
    nil
  }
```

Keep the optional fallback visible. Do not add helpers solely to hide a small conditional.

### Review behavior while changing style

Check evaluation order as well as the returned value. Preserve `await` placement, database
transaction boundaries, approval signalling, cancellation, task registration, and weak captures.
For actor code, moving an operation across an `await` can change behavior even if the final
statements look equivalent. Preserve runtime string contents, including log messages.

## Setup

Use the compiler and formatter bundled with the pinned distribution:

| Platform | Distribution | Compiler identity | Apple formatter report |
| --- | --- | --- | --- |
| macOS | Xcode **27.0**, build **27A266a** | Apple Swift **6.4**, `swiftlang-6.4.0.34.1 clang-2100.3.34.1` | `main` |
| Linux | Official **Swift 6.4.0** release (`swift:6.4.0-noble`) | Swift **6.4**, `swift-6.4-RELEASE` | `main` |

[`.swift-version`](../.swift-version) pins the Swift version; the remaining pins live in
[`BuildTools/lint-versions.env`](../BuildTools/lint-versions.env). Both package manifests require
Swift tools 6.4. `scripts/check-toolchain.sh` verifies the compiler identity and, on macOS,
the Xcode version and build. The formatters' `main` label is diagnostic, not a version pin.

For an Xcode installation at `/Applications/Xcode.app`, select its tools in your current shell:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
unset TOOLCHAINS
export PATH="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH"
scripts/check-toolchain.sh
```

Adjust `DEVELOPER_DIR` if you installed Xcode elsewhere. The lint gate uses
`xcrun --toolchain XcodeDefault swift-format` on macOS and `swift format` on Linux.

Install SwiftLint **0.65.1** from its
[official release](https://github.com/realm/SwiftLint/releases/tag/0.65.1). Homebrew is usable
when `swiftlint version` matches that pin. The lint gate builds SwiftFormat **0.62.1** from
the locked BuildTools dependency, so the first run needs network access. It checks prerequisites
before changing source; you do not need a global `swiftformat` install. A whole-repository
check also needs Python 3 for its dead-code stage; macOS includes it with the Xcode tools.

On Linux, install the same SwiftLint release as CI:

```bash
source BuildTools/lint-versions.env
curl --fail --location --silent --show-error \
  "https://github.com/realm/SwiftLint/releases/download/${CLAW_LINT_SWIFTLINT_VERSION}/swiftlint_linux_amd64.zip" \
  --output /tmp/swift-claw-swiftlint.zip
printf '%s  /tmp/swift-claw-swiftlint.zip\n' "$CLAW_LINT_SWIFTLINT_LINUX_SHA256" | sha256sum --check
mkdir -p .build/swiftlint
unzip -q /tmp/swift-claw-swiftlint.zip -d .build/swiftlint
export PATH="$PWD/.build/swiftlint:$PATH"
scripts/check-toolchain.sh
```

This archive is for Linux amd64. `curl`, `unzip`, and `sha256sum` must be installed.
The [lint workflow](../.github/workflows/lint.yml) shows the complete container setup.
SwiftLint must be able to read temporary files outside the checkout, so a Docker wrapper that
mounts only the repository cannot implement this native executable contract.

For actionlint, zizmor and ShellCheck, use the versions in `BuildTools/lint-versions.env`
and the [local workflow checks](LOCAL_DEV.md#workflow-and-shell-checks).

## Daily workflow

```bash
scripts/lint.sh --fix
git diff                  # inspect corrections and runtime string contents
scripts/lint.sh
swift build
swift test
```

No arguments selects all maintained Swift files, including tests, package manifests, and build
tools. Dependencies, generated builds, and audit/formatter fixture text are excluded. Untracked
Swift files in maintained source directories participate too. Limit an iteration to named files:

```bash
scripts/lint.sh --fix Sources/ClawCore/Domain/Bot/Command.swift
scripts/lint.sh Sources/ClawCore/Domain/Bot/Command.swift
```

Check mode leaves source untouched and reports files whose canonical formatting differs.
Fix mode applies the same pipeline. Stage names and elapsed times identify a running formatter
or SwiftFormat build; SwiftPM's dependency/build diagnostics remain visible. Correctness errors
can still require a manual edit after formatting. Existing line breaks are preserved so reviewed
multiline layouts survive subsequent formatting.

SwiftLint warnings are advisory by default; `STRICT=1 scripts/lint.sh` also rejects warnings.
Errors, including the 100-character source line limit, always fail. Comments and URLs are
exempt. Wrap long string literals manually while preserving their runtime contents; individual
opaque-value suppressions require the reason prescribed in the architecture.

## Editor formatting

`.editorconfig` supplies basic whitespace defaults. Configure an editor's external formatter to
send its **current buffer** to this command with the buffer's real repository file path:

```bash
/absolute/path/to/swift-claw/scripts/lint.sh --format-stdin /absolute/path/to/swift-claw/Sources/Example.swift
```

Use stdout as the replacement buffer only after a successful exit. Diagnostics go to stderr;
the command does not write the on-disk source. The real path selects nested configuration, such
as `Tests/.swiftlint.yml`, even for an unsaved buffer. An editor that cannot pipe its buffer can
run `scripts/lint.sh --fix <saved-file>` after saving and reload the file. Avoid overlapping
formatter-on-save integrations: invoking Apple swift-format alone can undo the final Google
layout. Xcode users can run the saved-file command from a terminal or external-tool integration;
`.editorconfig` by itself does not install an Xcode formatter.

Python scripts follow `.ruff.toml`, as
[architecture §19.2](ARCHITECTURE.md#192-source-formatting-and-lint) describes. An editor's ruff
integration applies it; from a terminal, run `ruff format` and then `ruff check` on the changed
scripts.

## Review the seven sections

The existing tools cover mechanical layout. The following details remain manual review checks:

- Import ordering, conditional-import grouping, and necessity of each import.
- Blank lines between protocol requirements and short members.
- Multiline closure bodies, wrapped closure signatures, and short calls containing multiline closures.
- Multiline `do` and `catch` bodies, including single-statement bodies.
- Multiline nonempty type and extension bodies.
- Vertical inheritance lists, unnecessary line breaks, and unusual continuation layouts.
- Keep function signature tokens from `)` through `async`, `throws`, and `->` together.
  Wrap parameters vertically when needed; review existing breaks around effects manually.
- Naming, declaration responsibility, and accurate documentation contracts.
- [Readability and control flow](#readability-and-control-flow): meaningful result names,
  logical step boundaries, clear checks, and unchanged evaluation order.

Reviewers apply all seven sections in context:

| Phase | Review focus |
| --- | --- |
| 1. Source File Basics | Meaningful filenames; UTF-8; short escapes; invisible characters and literal contents. |
| 2. Source File Structure | Imports; related declarations and overloads; responsibility-based extensions. |
| 3. General Formatting | Readable 100-column layout; wrapping; whitespace; statement and closure bodies. |
| 4. Formatting Specific Constructs | Comments, properties, switches, enum cases, closures, commas, literals, attributes. |
| 5. Naming | API clarity; initialisms such as `runID`; meaningful argument and closure-parameter roles. |
| 6. Programming Practices | Initialization, optionals, error contracts, access, control flow, literal typing, arithmetic. |
| 7. Documentation Comments | Concise summaries; useful contract details; accurate parameters, results, and failures. |

Preserve serialized keys and stored values when renaming Swift symbols. Use explicit coding keys
when synthesized serialization would otherwise change. Keep public access when moving extension
modifiers to members. Style corrections must preserve test scenarios and observable behavior.

A passing formatter cannot certify naming quality or every semantic rule. When updating the guide
or tooling, review the affected sections, run `scripts/test-lint.sh`, verify a second fix makes no
changes, and run the normal lint/build/test gate. Keep the pins, CI, contributor instructions, and
this document aligned.
