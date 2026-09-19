# Contributing

Thanks for your interest in swift-claw.

Please follow our [Code of Conduct](CODE_OF_CONDUCT.md) in project spaces. It also
explains how to report unacceptable behavior privately.

## Open an issue first

Please open an issue and agree on the approach before sending a pull request.
swift-claw is a single-maintainer project with a normative spec; a short issue
discussion saves you from building something that can't merge. Small fixes
(typos, broken links, obvious one-liners) can skip straight to a PR.

Use the [issue chooser](https://github.com/ivan-magda/swift-claw/issues/new/choose)
for bug reports, feature requests, and documentation improvements. Blank issues remain
available for questions and other project work.

For bug reports, include your version, platform, steps to reproduce, and the output of
`clawd doctor --json` when available (or explain why it cannot run). Doctor redacts
secrets, but review diagnostics and log excerpts for private information before posting.
Never attach credentials, environment files, private conversations, or your state directory.

For vulnerabilities, never open a public issue. Follow [SECURITY.md](SECURITY.md).

## Development setup

Use the [pinned Swift style toolchain](docs/CODE_STYLE.md#setup): Swift 6.3.3,
Apple swift-format 6.3.0 on macOS / 6.3.3 on Linux, SwiftLint 0.65.1, and SwiftFormat 0.62.1. The lint script
validates versions before changing source; BuildTools supplies SwiftFormat from a
locked dependency. Its first run needs dependency access.
Linux development also needs `libsqlite3-dev` for GRDB.

The [Google Swift style workflow](docs/CODE_STYLE.md) covers installation, the seven
review sections, local exceptions, per-file checks, and editor formatting. CI calls
the same entry point:

```bash
scripts/lint.sh --fix  # apply the canonical Google/local style pipeline
git diff              # review the corrections
scripts/lint.sh        # verify
swift build
swift test
```

The gate reports its current stage and elapsed time. SwiftLint warnings are advisory
unless `STRICT=1` is set; errors always fail. Run the complete gate rather than
standalone formatter commands, whose intermediate layouts differ from the final
Google style. Tooling/configuration changes also run `scripts/test-lint.sh`.

Day-to-day commands, including how to run the daemon locally, live in
[docs/LOCAL_DEV.md](docs/LOCAL_DEV.md).

## What a pull request needs

- A linked issue with an agreed approach (except trivial fixes).
- For Swift changes, `scripts/lint.sh`, then `swift build`, then `swift test` green.
  CI runs the tests on macOS and Linux, and the lint gate on Linux. For documentation-only
  changes, check affected links, examples, and template syntax as applicable.
- Tests for behavior changes, structured as Given-When-Then
  (`// given` / `// when` / `// then`). [docs/TESTING.md](docs/TESTING.md) is
  the rubric for what earns a test.
- Design changes reflected in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
  That document is normative: where code and spec disagree, the spec wins,
  so change both together.

## Ground rules

- Swift 6 strict concurrency throughout: actors own mutable asynchronous state; domain
  types are `Sendable` value types. Preserve the GRDB and synchronous-lock contracts in
  [ARCHITECTURE.md §5.2](docs/ARCHITECTURE.md#52-dependencies-and-state).
- Security policy is enforced in code, never in the prompt. Untrusted input
  (messages, web content, tool output, stored memory) is data, not instructions.
- Reuse before you add: search for an existing helper, constant, or test double
  before writing a second copy.
