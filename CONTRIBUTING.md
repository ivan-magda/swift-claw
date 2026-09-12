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

You need a Swift 6.3 toolchain and SwiftLint (the lint gate exits 1 without it). The gate's
third tool, SwiftFormat, needs no install — `scripts/lint.sh` runs it out of the `BuildTools`
package at a pinned version, so the first run builds it and needs network access.

```bash
# macOS
brew install swiftlint

# Linux
sudo apt-get install -y libsqlite3-dev          # SQLite headers GRDB links against
docker pull ghcr.io/realm/swiftlint:0.65.0      # the image CI lints with
```

On Linux, put a wrapper on your `PATH` so `scripts/lint.sh` finds SwiftLint and runs the
same checks as everywhere else:

```bash
sudo tee /usr/local/bin/swiftlint >/dev/null <<'EOF'
#!/bin/sh
exec docker run --rm -v "$PWD:$PWD" -w "$PWD" \
  --entrypoint swiftlint ghcr.io/realm/swiftlint:0.65.0 "$@"
EOF
sudo chmod +x /usr/local/bin/swiftlint
```

Mounting the working directory at its own path keeps the paths SwiftLint prints usable on
the host. Run the
gate with `scripts/lint.sh` rather than calling `swiftlint` yourself: warnings are not
failures by default, so a bare `--strict` run reports the accepted warnings
and exits nonzero on a clean checkout.

Then:

```bash
swift build            # build
swift test             # run the suite
scripts/lint.sh --fix  # auto-apply layout, multiline conditional bodies, and SwiftLint fixes
scripts/lint.sh        # verify; must pass before committing
```

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

- Swift 6 strict concurrency throughout: mutable state lives in actors, domain
  types are `Sendable` value types.
- Security policy is enforced in code, never in the prompt. Untrusted input
  (messages, web content, tool output, stored memory) is data, not instructions.
- Reuse before you add: search for an existing helper, constant, or test double
  before writing a second copy.
