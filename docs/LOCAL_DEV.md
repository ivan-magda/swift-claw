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
scripts/lint.sh --fix   # auto-apply layout, multiline guard bodies, and SwiftLint fixes
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

`execute_code` is disabled by default. When enabled with no `CLAW_EXEC_IMAGE` set, clawd uses
its built-in default pin, the image verified for this release
(`PinnedImageReference.verifiedDefault` in `Sources/ClawCore/Config/ExecConfig.swift`):

```text
cgr.dev/chainguard/python@sha256:55cd38584d1bba1913a1d58da07184cbe512724bc03e822e269404c73cd4c9cd
```

The pinned arm64 image provides `/usr/bin/python` (Python 3.14) and `/bin/sh`, has OCI
ENTRYPOINT `["/usr/bin/python"]`, and runs as nonroot uid `65532`. clawd always supplies an
explicit entrypoint.

Set `CLAW_EXEC_IMAGE` only to override the default with a pin you verified yourself; the value
must be a digest-pinned reference from an allowlisted registry, and an invalid value fails the
config outright instead of falling back to the default. Never copy a moving tag into
`CLAW_EXEC_IMAGE`. The procedure below qualified the default pin; run it for any override or
default rotation:

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

Enabling execution needs one line in `~/.swift-claw/clawd.env`; every other `CLAW_EXEC_*`
variable has a usable default (built-in verified image pin, registries `cgr.dev`, 1024 MiB,
4 CPUs, 30 s, no egress):

```bash
CLAW_EXEC_ENABLED=true
```

Set the other `CLAW_EXEC_*` variables (see `.env.example`) only to override a default.

Rotate the default pin on an upstream advisory or an intentional maintenance review. Repeat
signature plus all three attestation checks, interpreter/user inspection, hardening canary, and
the mandatory `ContainerBackendRealAcceptanceTests` command before changing
`PinnedImageReference.verifiedDefault`, then update the digest cited in this file and any
configured `CLAW_EXEC_IMAGE` overrides. Automated mirroring and refresh scheduling are outside
this increment.

---

## Running execute_code (macOS 26 arm64)

`execute_code` is a `dangerous` tool: even when enabled it never auto-runs. Every call suspends the
turn and sends the owner the complete redacted script, the staged-inputs table, the egress mode, and
a taint banner when the turn ingested untrusted content. The tool runs only after the owner approves
that exact action from Telegram.

**Enable it.** Set `CLAW_EXEC_ENABLED=true` in `~/.swift-claw/clawd.env`, then restart `clawd`.
The built-in verified pin (previous section) is used unless `CLAW_EXEC_IMAGE` overrides it.

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
when the `container` CLI is missing or below `1.0.0`, or when any hardening canary assertion failed.
An unpinned `CLAW_EXEC_IMAGE` override is stricter still: config validation rejects it and the
process exits 10, so no daemon runs at all. An owner-enabled sandbox that fails a gate prints a loud
error row rather than silently degrading.

---

## Voice-message transcription (macOS 26)

Telegram voice notes are transcribed **on-device** with Apple's `SpeechAnalyzer` stack and the
transcript enters the normal turn flow — fenced and session-tainting, since a forwarded voice note
is indistinguishable from the owner's own (see `ARCHITECTURE.md` §6.1/§12). On by default on hosts
with the speech stack; one line opts out:

```bash
CLAW_VOICE_TRANSCRIPTION=false
```

`CLAW_VOICE_LOCALES` picks the transcription languages — a comma-separated BCP-47 list in
priority order (default `en-US`). There is no audio-language auto-detection anywhere in Apple's
stack, so every configured locale transcribes the note and the most confident transcript wins; a
locale without a `SpeechTranscriber` model (e.g. `ru-RU`) runs on the older system-dictation
`DictationTranscriber` model instead. A bilingual host sets one line:

```bash
CLAW_VOICE_LOCALES=ru-RU,en-US
```

Audio matching none of the configured languages gets a canned "couldn't make out that voice
message" reply instead of a garbage transcript. The **first** voice message in a locale downloads
its speech model (one-time, needs network, no UI); transcription itself runs offline. File-based
transcription needs no TCC grant, entitlement, or app bundle.

On Linux or macOS 15 the flag is inert and voice messages get the canned "I can't read voice
messages yet." reply — same behavior as before the feature.

The suite's engine test is opt-in (first model download needs network):

```bash
CLAW_SPEECH_LIVE_TESTS=1 swift test --filter AppleSpeechTranscriberLiveTests
```

Background research (verified capability matrix, the Ogg/Opus decode findings, the
LaunchDaemon-vs-LaunchAgent open question):
`docs/research/telegram-voice-transcription-2026-07-16.md`.

---

## Inbound images

A photo you send is downloaded and passed to the model with its caption, and — like a voice note —
enters the turn flow fenced and session-tainting, since a forwarded photo is indistinguishable from
one the owner shot. The bytes are held in memory only, never written to disk, and they outlive the
run that stored them so a photo sent in one message and questioned in the next still reaches the
model as pixels. A restart loses them.

On by default; one line opts out:

```bash
CLAW_IMAGE_INPUT=false
```

This needs a **vision-capable `CLAW_LLM_MODEL`** — a text-only model rejects the request outright,
and nothing in the daemon can detect that ahead of time, so the knob is the only control. With the
feature off, a bare photo gets the canned "I can't read photos yet." reply, but a **captioned** one
still runs as a turn carrying the caption: opting out of pixels does not throw away your question.

---

## Secrets

### Seal (first-time setup)

Reads `CLAW_TELEGRAM_BOT_TOKEN`, `CLAW_LLM_API_KEY`, `CLAW_SEARCH_API_KEY`, and
`CLAW_LLM_FALLBACK_API_KEY` from the environment and writes two files under
`~/.swift-claw/`:

- `secrets.enc` — encrypted envelope
- `secret.key` — AES key (mode 0600)

```bash
set -a && source ~/.swift-claw/clawd.env && set +a
.build/debug/clawd secrets seal
```

Sealing also blanks all four of those lines in the env file and prints what it changed.
`--no-scrub` leaves them in place; `--env-file <path>` targets a file other than
`$CLAW_ENV_FILE` / `~/.swift-claw/clawd.env`. The non-secret config
(`CLAW_LLM_BASE_URL`, `CLAW_LLM_MODEL`, etc.) is untouched.

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

## ChatGPT subscription auth

An optional route that runs an eligible OpenAI model against a ChatGPT
subscription instead of an API key. Selected entirely by `CLAW_LLM_MODEL`:
set it to `openai-chatgpt/<model>` and `CLAW_LLM_BASE_URL` / `CLAW_LLM_API_KEY`
are neither required nor used. There is no token environment variable — the
credential lives encrypted in the state root.

> **Unofficial, vendor-dependent route.** This is behavior observed in two
> reference implementations (see `docs/research/`), **not a public, supported
> third-party ChatGPT API.** The endpoints, headers, and flow can change or be
> withdrawn without notice, and your subscription's terms govern its use. The
> OpenAI-compatible route stays the supported default — one `CLAW_LLM_MODEL`
> change away.

### Stop the daemon first

`login` and `logout` mutate the credential and take the same single-instance
lock the daemon holds, so **stop `clawd` first** (`Ctrl-C`, or `launchctl` stop
under a service manager). They fail with a clear stop-the-daemon message if the
lock is held. `status` is read-only and safe to run against a live daemon.

### Log in

```bash
set -a && source ~/.swift-claw/clawd.env && set +a
.build/debug/clawd auth login
```

Login prints a verification URL and a user code; open the URL, enter the code,
and approve in the browser. On success it seals your environment secrets into
the encrypted backend (if not already sealed), stores the refreshable
credential, fetches the eligible model list, and prints the exact assignment:

```text
CLAW_LLM_MODEL=openai-chatgpt/gpt-5.4
```

**Model selection.** On a TTY, login lists the discovered models and prompts you
to pick one by number (the default is your currently configured ChatGPT model,
else the first listed). With no TTY (piped/non-interactive), it selects that same
default without prompting and explains the choice. If the catalog fetch fails,
login still succeeds and prints the manual form
`CLAW_LLM_MODEL=openai-chatgpt/<model>` for you to complete.

**Copy the printed assignment** into `~/.swift-claw/clawd.env` yourself — login
never edits `.env`, a plist, or shell files. Then restart the daemon.

### Status

```bash
.build/debug/clawd auth status
```

Reports provider, presence, expiry, freshness (`fresh` / `expiring` / `expired`),
and the configured model — never any token bytes or account ID. It never
refreshes or contacts the network.

### Log out

```bash
.build/debug/clawd auth logout
```

Removes the stored credential (idempotent). **Logout is local deletion, not
server-side revocation** — an already-issued access token may stay valid at the
vendor until its own expiry. It does not touch `secret.key` or `secrets.enc`.

### Doctor

`doctor --check-config` adds a network-free `llm.auth` row. On this route a
usable credential shows
`provider=openai-chatgpt mode=oauth status=<fresh|expiring|expired-refresh-on-use>`
(an OK row); no usable credential is a failing row with `run: clawd auth login`
guidance; a malformed envelope is a failing decrypt row. Doctor never refreshes,
fetches models, or contacts ChatGPT.

### Expired credentials, access, and quota

The daemon refreshes the access token automatically before each call while a
valid refresh token exists — an `expiring`/`expired` status is normal and needs
no action. Only when refresh itself is rejected (a revoked or reused refresh
token) does a turn fail with **"stop clawd, run `clawd auth login`"** guidance;
that is the sole case needing a fresh login. **Entitlement and quota failures do
not tell you to log in:** an access denial means the subscription/account cannot
use that route or model; a quota/throttle failure tells you to retry after the
reported delay or plan reset. Logging in again fixes neither.

### Backups

`secret.key` (the AES key) must stay **out of your backup boundary**, exactly as
for `secrets.enc`. The ChatGPT credential envelope (`llm-credentials.enc`) and the
MCP token envelope (`mcp-credentials.enc`) are encrypted with that same key, so a
backup that excludes the key cannot decrypt them. A restore without the key — or a crash during a vendor
token rotation — can require a fresh `clawd auth login`.

---

## MCP servers

Point clawd at an MCP server by writing `<state root>/mcp.yaml` (or setting
`CLAW_MCP_CONFIG`). The file format and the trust rules are in
[CUSTOMIZATION.md](CUSTOMIZATION.md#mcp-servers); this is the local loop.

```bash
.build/debug/clawd mcp list                  # config + token state, no network
.build/debug/clawd mcp probe                 # connect + initialize + tool count, exits 1 on any failure
.build/debug/clawd mcp probe linear          # one server, even a disabled one
printf '%s' "$TOKEN" | .build/debug/clawd mcp set-token linear
```

`set-token` and `clear-token` take the state-root lock, so stop the daemon first;
`list` and `probe` are read-only and safe against a running one. A full
`clawd doctor` prints the same offline rows plus a live probe row per server,
and `--check-config` stays offline.

`probe` is the fastest way to tell a config mistake from a server problem: it
reports what each server answered, and the tool count it prints is what **your**
include/exclude filter admits, not the server's full catalog.

A server that is simply down makes `clawd doctor` exit 1 and withhold the start
command, even though the daemon itself would boot fine without it. `clawd run`
directly is the way past that while you work on something else.

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
| `llm-credentials.enc` | ChatGPT OAuth credential (encrypted; only on that route) |
| `mcp.yaml`    | MCP server catalog (optional; absent = no MCP tools) |
| `mcp-credentials.enc` | MCP server tokens (encrypted; only once you set one) |

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
