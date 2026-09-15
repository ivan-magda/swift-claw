# Swift code style

swift-claw follows the [Google Swift Style Guide](https://google.github.io/swift/), including
its reference to the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/).
The adopted revision, explicit local exceptions, and tool ownership are normative in
[ARCHITECTURE.md §19.2](ARCHITECTURE.md#192-source-formatting-and-lint).

## Local rules and exceptions

- Nonempty conditional/loop statements and closure bodies are multiline; inline `if` expressions
  remain allowed.
- Wrapped condition lists begin on the line after the keyword.
- Group private helpers in `private extension` blocks with an immediately preceding
  `// MARK: - <Group Name>`. Put other access modifiers on members.
- Structure tests with `// given`, `// when`, and `// then`.
- Keep documentation summaries concise, normally one or two lines; add necessary contract
  details and tags. Ordinary comments explain enduring constraints.
- The 100-character gate exempts comments and URLs. An intact opaque literal needs a reasoned
  single-line suppression, as specified in the architecture.
- Preserve the `ClawCore` seam/error placement when considering Google's nesting preference.
- The pinned Subprocess SDK's `Environment.Key(stringLiteral:)` is a narrow dynamic-key
  exception until that API exposes a suitable public nonfailable alternative.

## Setup

Use Swift **6.3.3**, SwiftLint **0.65.1**, and SwiftFormat **0.62.1**. The bundled Apple
swift-format reports **6.3.0** in Xcode on macOS and **6.3.3** in the Linux toolchain;
the gate checks the exact platform-specific version. The checked pins live in
[`BuildTools/lint-versions.env`](../BuildTools/lint-versions.env); `.swift-version` selects the
Swift toolchain for tools that support it. SwiftFormat builds from the locked `BuildTools`
package on the first run, which needs dependency access.

On macOS, select the matching Xcode toolchain and install SwiftLint 0.65.1 from its
[official release](https://github.com/realm/SwiftLint/releases/tag/0.65.1). Homebrew is also
usable when its installed version matches the pin. Check `swift --version`,
`swift format --version`, and `swiftlint version`; the gate rejects mismatches before changing
source files. Installing another version and bypassing that check is not a supported setup.

On Linux, use the Swift 6.3.3 toolchain and install the same SwiftLint release as CI:

```bash
source BuildTools/lint-versions.env
curl --fail --location --silent --show-error \
  "https://github.com/realm/SwiftLint/releases/download/${CLAW_LINT_SWIFTLINT_VERSION}/swiftlint_linux_amd64.zip" \
  --output /tmp/swift-claw-swiftlint.zip
printf '%s  /tmp/swift-claw-swiftlint.zip\n' "$CLAW_LINT_SWIFTLINT_LINUX_SHA256" | sha256sum --check
mkdir -p .build/swiftlint
unzip -q /tmp/swift-claw-swiftlint.zip -d .build/swiftlint
export PATH="$PWD/.build/swiftlint:$PATH"
```

This archive is for Linux amd64. `curl`, `unzip`, and `sha256sum` must be installed.
The [lint workflow](../.github/workflows/lint.yml) shows the complete container setup.
SwiftLint must be able to read temporary files outside the checkout, so a Docker wrapper that
mounts only the repository cannot implement this native executable contract.

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

## Review the seven sections

The existing tools cover mechanical layout. The following details remain manual review checks:

- Import ordering, conditional-import grouping, and necessity of each import.
- Blank lines between protocol requirements and short members.
- Multiline closure bodies, wrapped closure signatures, and short calls containing multiline closures.
- Vertical inheritance lists, unnecessary line breaks, and unusual continuation layouts.
- Keep function signature tokens from `)` through `async`, `throws`, and `->` together.
  Wrap parameters vertically when needed; review existing breaks around effects manually.
- Naming, declaration responsibility, and accurate documentation contracts.

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
