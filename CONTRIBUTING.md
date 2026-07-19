# Contributing

Thanks for your interest in swift-claw.

## Open an issue first

Please open an issue and agree on the approach before sending a pull request.
swift-claw is a single-maintainer project with a normative spec; a short issue
discussion saves you from building something that can't merge. Small fixes
(typos, broken links, obvious one-liners) can skip straight to a PR.

For bug reports, include your platform, the output of `clawd doctor --json`
(it redacts secrets), and steps to reproduce.

For vulnerabilities, never open a public issue. Follow [SECURITY.md](SECURITY.md).

## Development setup

You need a Swift 6.3 toolchain and SwiftLint (the lint gate exits 1 without it):

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
failures by default, so a bare `--strict` run reports the accepted force-unwrap warnings
and exits nonzero on a clean checkout.

Then:

```bash
swift build            # build
swift test             # run the suite
scripts/lint.sh --fix  # auto-apply swift-format + SwiftLint fixes
scripts/lint.sh        # verify; must pass before committing
```

Day-to-day commands, including how to run the daemon locally, live in
[docs/LOCAL_DEV.md](docs/LOCAL_DEV.md).

## What a pull request needs

- A linked issue with an agreed approach (except trivial fixes).
- `scripts/lint.sh` and `swift test` green. CI enforces both on macOS and Linux.
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
