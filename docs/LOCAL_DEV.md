# Local Development Guide

Day-to-day commands for building, running, and operating `clawd` locally.

---

## Prerequisites

`clawd` reads config from environment variables. The file `~/.swift-claw/clawd.env`
holds those variables but is never loaded automatically — you source it before each
invocation. Get in the habit of doing this at the start of a dev session:

```bash
set -a && source ~/.swift-claw/clawd.env && set +a
```

All commands below assume a sourced shell unless noted.

---

## Build

```bash
swift build
```

The debug binary lands at `.build/debug/clawd`. For a release build:

```bash
swift build -c release
```

---

## Lint

```bash
scripts/lint.sh --fix   # auto-apply swift-format + swiftlint fixes
scripts/lint.sh         # verify; must pass before committing
```

CI runs the check step. Fix before pushing.

---

## Tests

```bash
swift test                                    # full suite
swift test --filter SuiteName/testName       # single test
```

Tests follow Given-When-Then. Check `// given` / `// when` / `// then` sections
when reading failures.

---

## Doctor

Checks config validity, secrets, database, and Telegram connectivity:

```bash
set -a && source ~/.swift-claw/clawd.env && set +a
.build/debug/clawd doctor
```

Config-and-secrets only (no DB or network):

```bash
.build/debug/clawd doctor --check-config
```

Machine-readable output:

```bash
.build/debug/clawd doctor --json
```

Healthy output shows `OK` on `config` and `backend=encrypted` (or
`backend=env (WARN: plaintext)` before sealing).

---

## Secrets

### Seal (first-time setup)

Reads `CLAW_TELEGRAM_BOT_TOKEN` and `CLAW_LLM_API_KEY` from the environment
and writes two files under `~/.swift-claw/`:

- `secrets.enc` — encrypted envelope
- `secret.key` — AES key (mode 0600)

```bash
set -a && source ~/.swift-claw/clawd.env && set +a
.build/debug/clawd secrets seal
```

After sealing, remove the two secret lines from `clawd.env`:

```
# delete or blank these after sealing:
CLAW_TELEGRAM_BOT_TOKEN=...
CLAW_LLM_API_KEY=...
```

Keep the non-secret config (`CLAW_LLM_BASE_URL`, `CLAW_LLM_MODEL`, etc.).

### How the daemon picks up secrets

Once `secrets.enc` and `secret.key` exist in the state root, the resolver
uses the encrypted backend automatically. No extra env var needed. If either
file is present but broken, the daemon refuses to start rather than falling
back to plaintext env.

Verify with `doctor`: look for `secrets: backend=encrypted`.

---

## Run

```bash
set -a && source ~/.swift-claw/clawd.env && set +a
.build/debug/clawd run
```

The daemon long-polls Telegram, routes messages, and runs LLM turns.
Stop with `Ctrl-C`. A second instance against the same state root will
exit immediately (lock guard).

---

## State root

Default: `~/.swift-claw/`. Contents:

| File          | Purpose                       |
| ------------- | ----------------------------- |
| `claw.sqlite` | Main database (WAL mode)      |
| `clawd.env`   | Non-secret config             |
| `clawd.lock`  | Single-instance lock          |
| `secrets.enc` | Encrypted secrets envelope    |
| `secret.key`  | AES key (keep out of backups) |

Override the state root with `CLAW_STATE_ROOT` for isolated test setups.
