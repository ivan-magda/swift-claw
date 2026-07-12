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

> The release binary links the **system** SQLite (GRDB uses `libsqlite3`, not a vendored copy). On Linux the target host needs `libsqlite3-0`; on macOS it's part of the OS. Released Linux binaries are built with `--static-swift-stdlib`, so the Swift runtime is bundled and only `libsqlite3` is an external dependency.

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

Running a fake-IP VPN/proxy (sing-box / Clash / Surge-style)? The `dns.fake_ip`
row reports whether a canary probe sees your DNS answered from `198.18.0.0/15`.
`web_fetch` auto-allows probe-confirmed answers in that range; for a non-default
pool set `CLAW_WEBFETCH_EXEMPT_CIDRS` (see `.env.example`).

---

## Sandbox workload image (macOS 26 arm64)

`execute_code` is disabled by default and the distribution does not silently select an image.
The verified development image pin for this release is:

```text
cgr.dev/chainguard/python@sha256:55cd38584d1bba1913a1d58da07184cbe512724bc03e822e269404c73cd4c9cd
```

The pinned arm64 image provides `/usr/bin/python` and `/bin/sh`, has OCI ENTRYPOINT
`["/usr/bin/python"]`, and runs as nonroot uid `65532`. clawd always supplies an explicit
entrypoint. Re-verify before replacing the digest; never copy a moving tag into
`CLAW_EXEC_IMAGE`.

```bash
brew install cosign

set -euo pipefail
IMAGE_TAG=cgr.dev/chainguard/python:latest-dev
IMAGE_DIGEST=sha256:55cd38584d1bba1913a1d58da07184cbe512724bc03e822e269404c73cd4c9cd
IMAGE_REF=cgr.dev/chainguard/python@${IMAGE_DIGEST}
ISSUER=https://token.actions.githubusercontent.com
IDENTITY='^https://github.com/chainguard-images/images/.github/workflows/release.yaml@refs/heads/main$'
EVIDENCE_DIR="${HOME}/.swift-claw/image-evidence/${IMAGE_DIGEST#sha256:}"
install -d -m 0700 "${EVIDENCE_DIR}"

/usr/local/bin/container image pull \
  --scheme https --progress none --platform linux/arm64 "${IMAGE_TAG}"
/usr/local/bin/container image inspect "${IMAGE_TAG}" | grep -q "${IMAGE_DIGEST}"

cosign verify \
  --certificate-oidc-issuer "${ISSUER}" \
  --certificate-identity-regexp "${IDENTITY}" "${IMAGE_REF}" \
  > "${EVIDENCE_DIR}/signature.json"
cosign verify-attestation --type https://slsa.dev/provenance/v1 \
  --certificate-oidc-issuer "${ISSUER}" \
  --certificate-identity-regexp "${IDENTITY}" "${IMAGE_REF}" \
  > "${EVIDENCE_DIR}/slsa-v1.intoto.jsonl"
cosign verify-attestation --type https://apko.dev/image-configuration \
  --certificate-oidc-issuer "${ISSUER}" \
  --certificate-identity-regexp "${IDENTITY}" "${IMAGE_REF}" \
  > "${EVIDENCE_DIR}/apko.intoto.jsonl"
cosign verify-attestation --type https://spdx.dev/Document \
  --certificate-oidc-issuer "${ISSUER}" \
  --certificate-identity-regexp "${IDENTITY}" "${IMAGE_REF}" \
  > "${EVIDENCE_DIR}/spdx.intoto.jsonl"
test -s "${EVIDENCE_DIR}/signature.json"
test -s "${EVIDENCE_DIR}/slsa-v1.intoto.jsonl"
test -s "${EVIDENCE_DIR}/apko.intoto.jsonl"
test -s "${EVIDENCE_DIR}/spdx.intoto.jsonl"

/usr/local/bin/container run --rm \
  --scheme https --progress none --platform linux/arm64 \
  --network none --no-dns --cap-drop ALL --read-only --tmpfs /tmp \
  --entrypoint /bin/sh "${IMAGE_REF}" -c '
    test -x /usr/bin/python
    test -x /bin/sh
    test "$(id -u)" = 65532
  '
```

After those checks pass, set the non-secret execution configuration in
`~/.swift-claw/clawd.env`:

```bash
CLAW_EXEC_ENABLED=true
CLAW_EXEC_IMAGE=cgr.dev/chainguard/python@sha256:55cd38584d1bba1913a1d58da07184cbe512724bc03e822e269404c73cd4c9cd
CLAW_EXEC_IMAGE_REGISTRIES=cgr.dev
CLAW_EXEC_MEMORY_MIB=1024
CLAW_EXEC_CPUS=4
CLAW_EXEC_TIMEOUT=30
CLAW_EXEC_ALLOW_EGRESS=false
```

Re-pin on an upstream advisory or an intentional maintenance review. Repeat signature plus all
three attestation checks, interpreter/user inspection, hardening canary, and the mandatory
`ContainerBackendRealAcceptanceTests` command before changing the configured digest. Automated
mirroring and refresh scheduling are outside this increment.

---

## Running execute_code (macOS 26 arm64)

`execute_code` is a `dangerous` tool: even when enabled it never auto-runs. Every call suspends the
turn and sends the owner the complete redacted script, the staged-inputs table, the egress mode, and
a taint banner when the turn ingested untrusted content. The tool runs only after the owner approves
that exact action from Telegram.

**Enable it.** After pinning and verifying the image (previous section), set `CLAW_EXEC_ENABLED=true`
and the `CLAW_EXEC_*` block in `~/.swift-claw/clawd.env`, then restart `clawd`.

**Confirm the sandbox is healthy.** `clawd doctor` prints a `sandbox` row built from one
`SandboxMaintenance.prepare()` (host/version gates, then a hardening canary). A ready row means every
gate passed and the tool is registered:

```bash
clawd doctor
```

Expect `sandbox` with `available`, `os_ok`, `version_ok`, `image_digest_ok`, `caps_empty`,
`net_isolated`, `caps_match`, `reaper_ok`, `rootfs_ro`, `staging_ro`, and `interpreters_ok` all true
and an empty `last_error`. `clawd doctor --check-config` validates the config (digest-pin format and
registry allowlist) and the host/version gates without booting a canary.

**Egress is opt-in and gated.** A `network:false` run has no route out. A `network:true` run needs
`CLAW_EXEC_ALLOW_EGRESS=true` and shows `egress: yes` with a warning in the approval prompt; the run
is treated as able to exfiltrate, so its output taints the session and forces the next outbound tool
call through the trifecta approval.

**If the tool never appears** (calls are refused as unknown), `clawd doctor` explains why. It is
absent — by design, fail-closed — on Linux, macOS 15, Intel macOS, with `CLAW_EXEC_ENABLED=false`,
with no or an unpinned `CLAW_EXEC_IMAGE`, when the `container` CLI is missing or below `1.0.0`, or
when any hardening canary assertion failed. An owner-enabled sandbox that fails a gate prints a loud
error row rather than silently degrading.

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

---

## Release gates — sandbox code execution

The increment is not complete until all of the following pass on a macOS 26 arm64 host with
`container >= 1.0.0`:

```bash
# 1. Full hermetic suite (Layer A + all unit/gate/backend doubles) is green.
swift build --build-tests
timeout 900 swift test --skip-build

# 2. Mandatory real-backend security suite (Layer B) is green — the SC6 sandbox proof.
set -a && source ~/.swift-claw/clawd.env && set +a
CLAW_REAL_SANDBOX_TESTS=1 timeout 1200 swift test \
  --filter ContainerBackendRealAcceptanceTests

# 3. Lint is clean.
scripts/lint.sh --fix
scripts/lint.sh

# 4. Doctor shows a ready sandbox row when enabled, and no leftover instances remain.
clawd doctor
container ls --all | grep clawd-exec- || echo "no leftover exec containers"
```

A skipped Layer-B run (no `CLAW_REAL_SANDBOX_TESTS`) is fine for ordinary CI but is not acceptable
completion evidence. Re-pinning the workload image on an advisory repeats the image verification
section and this checklist before the new digest ships.
