---
name: verify
description: Drive clawd's real CLI surface to verify a change end-to-end (build, doctor, config probes) without needing Telegram/LLM secrets.
---

# Verifying clawd changes at the CLI surface

Build once: `swift build` → binary at `./.build/debug/clawd`.

The daemon (`clawd run`) needs a real Telegram bot token, so most changes are verified through
the `doctor` surface, which exercises config loading, the state root, GRDB stores, and live
DNS/network rows without secrets.

## Minimal env handle

`AppConfig.load` fails closed without an LLM base URL/model. A scratch state root keeps the real
`~/.swift-claw` untouched:

```bash
CLAW_LLM_BASE_URL=http://localhost:9/v1 CLAW_LLM_MODEL=test-model \
CLAW_STATE_ROOT="$(mktemp -d)" ./.build/debug/clawd doctor
```

- Full `doctor` runs config + db + connectivity rows; `secrets` shows FAIL without a token —
  expected, not breakage.
- `doctor --check-config` is the config-only surface: fastest probe for new env keys
  (row output + fail-closed exit codes; invalid config exits 10).
- `doctor --json` for machine-readable assertions.

## Gotchas

- Piping doctor output through `grep` eats the exit code — capture `$?` on a separate run.
- This machine may run a fake-IP VPN/proxy: ALL hostnames (even nonexistent ones) can resolve
  into `198.18.0.0/15` (`dns.fake_ip` doctor row reports it). Anything asserting on real DNS
  answers must account for that.
- `timeout <s>` every clawd invocation; a hung doctor (network rows) should not park the session.
