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

## Group mode (Telegram forum supergroup)

Off by default. One variable turns it on — a comma-separated list of the chat ids `clawd` should
serve as a shared room instead of the owner's DM:

```bash
CLAW_GROUP_CHATS=-1001234567890
```

**One id covers a whole forum.** Every topic in a forum supergroup shares the supergroup's chat id
and differs only by `message_thread_id`, so you never list topics — `clawd` keeps one session per
topic on its own.

In a group the bot follows the text in a topic but answers only when addressed: an `@handle`
mention, a slash command, or a reply to something it said. Unaddressed text joins the topic's
transcript without starting a run. The bot does not download, transcribe, or store unaddressed
media. Tools execute without approval prompts, `/remember`,
`/memory`, `/schedule`, `/pause`, `/resume`, `/run` and `/cancel` are refused, and recall stays
inside the topic that asked. `docs/ARCHITECTURE.md` §12.1 is the normative description, including
what the mode trades away — **use a separate state root from your personal install**, because the
owner's `MEMORY.md`, `USER.md` and durable facts assemble into a group topic just as they do into
a DM.

### Onboarding order

The order matters — step 1 cannot be fixed later without removing and re-adding the bot.

1. **Turn privacy mode OFF at BotFather** — `/mybots` → your bot → _Bot Settings_ → _Group Privacy_
   → _Turn off_. With privacy mode on, Telegram delivers only commands and replies, so the bot
   cannot follow a conversation. Changing this **after** the bot has joined does not take effect
   until it is removed and added again. (Making the bot a group administrator is the alternative,
   and grants far more than reading.)
2. **Add the bot to the group.** It stays silent: an unlisted chat is ignored without a reply, so
   it never announces itself to a room it was added to uninvited.
3. **Read the chat id from the log.** Being added logs a line naming the room and its id:

   ```
   someone added the bot to chat -1001234567890 "iOS Crew" (supergroup): left → member
   ```

   A message sent in the room before it is configured logs the id too:

   ```
   ignoring update 42 from unlisted chat -1001234567890 "iOS Crew" (supergroup)
   ```

4. **Put the id in `CLAW_GROUP_CHATS`** in `~/.swift-claw/clawd.env`.
5. **Restart the daemon.** The list is read at boot only.

Verify with `doctor` — the `group.mode` row reports `off`, or `on (1 chat)` / `on (N chats)`:

```bash
.build/debug/clawd doctor --check-config | grep group.mode
```

A daemon configured with group chats **refuses to start** if it cannot resolve its own `@handle`
from Telegram, since that name is how it recognizes being addressed.

If Telegram upgrades the group to a supergroup, the chat id changes and the old one stops existing.
The daemon logs an error naming the new id and goes quiet in that room; edit `CLAW_GROUP_CHATS` and
restart. It will never re-point an access grant on its own.

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

| File                  | Purpose                                                  |
| --------------------- | -------------------------------------------------------- |
| `claw.sqlite`         | Main database (WAL mode)                                 |
| `clawd.env`           | Non-secret config                                        |
| `clawd.lock`          | Single-instance lock                                     |
| `secrets.enc`         | Encrypted secrets envelope                               |
| `secret.key`          | AES key (keep out of backups)                            |
| `llm-credentials.enc` | ChatGPT OAuth credential (encrypted; only on that route) |
| `mcp.yaml`            | MCP server catalog (optional; absent = no MCP tools)     |
| `mcp-credentials.enc` | MCP server tokens (encrypted; only once you set one)     |

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

## Coder workspace development

The native process runner and Git workspace preparation back the opt-in Coder tools. Local paths
refer to the daemon machine; native tools and their dependencies must already be installed.
The backend can be exercised without inference through its CLI fixtures.
Run the workspace fixtures with:

```bash
swift test --filter CoderWorkspaceTests
```

Workspace preparation uses `/usr/bin/git` with a minimal environment and disables global/system
Git configuration, optional locks, fsmonitor and hooks. It does no network work before approval.
In-place work keeps the checkout's current branch, staged changes and working files, including an
unborn branch before its first commit (recorded without a starting SHA). A separate
local copy starts at the requested committed ref (default: source HEAD), with independent objects
and no source hooks or configuration; dirty files are not copied. No automatic stash, rollback or
apply-back occurs. Job directories stay private under `<state-root>/coder/jobs/<UUID>/`; separate
repositories use `repository/`. Failure preserves partial work for inspection.

For PR requests, the intended GitHub owner/repository and explicit/default base selector are bound
before approval. Local `origin` URL rewrites are resolved, and effective fetch/push destinations must
name the same GitHub repository. Ambiguous origins, non-GitHub URLs and conflicting fork push URLs
are refused. Use an explicit GitHub source or an unambiguous local origin for such configurations.
A local origin change after approval is refused; Codex may create a head fork after admission.
These publication checks do not affect local-changes-only requests.

Observed changed paths compare actual starting file contents, executable bits and symlink targets,
so a committed fix remains visible even with clean final status. Inventory limits are 10,000 paths,
1 MiB of Git path output and 32 MiB of contents/targets. Oversized, unreadable or unsupported entries
(including submodule directories) make comparison unavailable; they do not mean no changes.
Symlinks are recorded without following them outside the repository. Concurrent editors can change
files during a task, so this evidence does not establish authorship. For remote inputs, preparation
allocates an empty destination for Codex to clone; a worker-reported initial SHA is not an independently
observed starting inventory. All admitted Git work shares the backend's one deadline and process
tracking, including preparation and inspection.

## Codex backend development

`ClawCoder.CodexBackend` implements one admitted task, composed at the daemon root with the Coder
service and its three Telegram-facing tools. Run the unmanaged CLI fixture against real temporary Git repositories with:

```bash
swift test --filter CodexBackendTests
```

The backend resolves the configured program once against the effective Coder child PATH, preserving
an explicit absolute executable. `CLAW_CODER_PATH` overrides that child only; when unset, the existing
process-PATH then `/usr/bin:/bin` fallback remains. `compatibility()` performs only bounded local
`--version` and `exec --help` probes. Jobs repeat the same validation under tracked process
supervision and their single deadline. Codex CLI 0.153.4 is the successful compatibility baseline; another installed version
must still expose all required flags. No inference, login, or GitHub publication is required by tests.

The argument vector is:

```text
codex exec --json --approve-for-me -c approval_policy="on-request"
  --skip-git-repo-check --ephemeral --color never -C <resolved-directory>
  --output-schema <private-schema-path> -o <private-result-path> -
```

A configured profile adds `--profile <name>` before the final `-`. The prompt is finite stdin,
not shell source. It names source, requested work, actual destination, initial ref, deliverable,
publication scope and a UUID-derived suggested branch. Codex performs its own Git/GitHub workflow,
including reusing an already-created matching PR. Repository/issue text cannot redefine that scope.

The schema is embedded in the executable, then copied into a private per-job protocol directory
with mode 0600; no schema resource sidecar is needed when relocating the binary. JSONL frames
are limited to 1 MiB and final reports to 64 KiB; final-report inspection refuses symlinks and
nonregular files. Unknown events are tolerated. Exit zero requires terminal completion and a valid
succeeded report before success assessment; permission blocks, execution and protocol failures remain
distinct. Summaries/diagnostics are redacted and capped, protocol files are removed after extraction,
and repositories remain available, including an existing partial destination after preparation
fails. If protocol-file removal fails, the result reports cleanup failure and those owner-only
files remain for operator recovery.

Local changed paths come from the independently captured initial content inventory. An unavailable
inventory leaves changed paths unknown without changing the observed local starting-commit provenance.
Remote initial
commits are worker-reported and never imply an observed baseline. Final branch/commit and commit
author come from sanitized Git queries. A PR needs read-only `gh` confirmation of the frozen
repository, observed head/commit and selected base; the default selector also requires `gh repo view`
to establish that repository's default. The GitHub actor is the confirmed PR's author, separate from
the Git commit author. Missing or unverifiable publication after possible execution remains unknown;
a requested PR with unknown publication cannot be an unqualified success.

The child environment and inherited installation trust are documented in
[CUSTOMIZATION.md](CUSTOMIZATION.md#coder-configuration). Run `clawd coder setup` from a terminal whose
PATH includes Codex and any interpreter used by it, then restart and inspect Telegram `/status` to
verify the effective service path's directory count and resolved Codex and `gh` executables, plus Node when present.
Configure existing Codex/gh authorization under the actual service account before live validation.
CLI presence and a foreground login are insufficient proof. Keep
paid probes, denied-action checks and cancellation probes in a dedicated temporary state root; the
scripted suite does not use or validate your personal daemon credentials.

## Coder background lifecycle and recovery

`ClawGateway.CoderService` supplies background task ownership over the Core seams. The daemon root
injects the same instance into the tools, boot reconciliation, service graph and fallback shutdown.
Its `start()` finishes before approval replay or new admission; `run()` participates in the service
graph and `shutdown()` closes admission, persists cancellation and joins all owned backend work
before outbox/database close. Approval replay can start work before ServiceGroup starts, so command
fallback joins that same service and checks its cleanup failure. The current lifecycle graph still
starts its registered services when the parent was cancelled during boot. Unresolved cleanup exits
without closing dependent clients underneath owned work.
Run the real-store, scripted-backend tests without inference or GitHub access:

```bash
swift test --filter 'CoderServiceTests|CoderRecoveryTests|CoderCompositionTests|RuntimeShutdownAcceptanceTests'
```

Enable Coder in the already-sourced `clawd.env`; no additional loader is used. `clawd doctor
--check-config` launches no Codex process. Full doctor and daemon startup use bounded local
`--version`, `exec --help` and unprofiled `login status` checks. These do not run inference, refresh
credentials, clone a repository or create a PR. Missing base login blocks unprofiled submission.
The CLI rejects `--profile <name> login status`; selected-profile authentication is explicitly
unverified in health while compatible approved jobs remain available. Profile-specific auth may fail
at execution. Do not infer profile readiness from the base login or import/merge authentication state.

For supervised live validation, use a dedicated temporary state root and an already-authorized
repository under the actual service user, HOME, PATH and selected Codex/GitHub auth context. Check the
local health facts first, then verify an approved daemon task, a denied native action and cancellation
through its cleanup receipt. Retain sanitized argv, exit/outcome and publication evidence; never dump
credentials, prompts or raw protocol output. A prior foreground success is not proof of daemon auth.
These live checks can incur child billing and are separate from the deterministic suite.

Ask in the owner DM to cancel `Coder job <UUID>`; `/stop` cancels the conversational turn, not an
already-admitted job. Completion uses existing outbox retries without another LLM turn. Child-reported
usage is kept with that job, separate from `/cost`; missing usage is unavailable accounting. Coder's
concurrency/timeout settings are not a hard dollar cap. v1 is owner DM only; full capacity returns busy.

Full doctor and daemon health read persisted reservations and the most recently updated
failed/timed-out/interrupted record, including released jobs and history from enabled runs when Coder
is now disabled. `doctor --check-config` does not read job history. Recovery can update the record
ordering; the timestamp is not immutable failure time. The CLI labels live service observations
unavailable, and failed storage reads as unreadable rather than zero/none. Current CLI/auth health
is separate from historical failure.

Cancellation returns a stopping job promptly, while its slot remains reserved through joined cleanup
and terminal persistence. The configured N slots allow independent jobs to run concurrently; a full
service returns busy. In-place checkout/common-Git identity conflicts return workspace busy even if
capacity remains. These locks coordinate only Coder's own jobs, not external editors or agents.

On daemon restart, unfinished tasks become interrupted and produce one durable completion notice,
even when `CLAW_CODER_ENABLED=false`. Disabling removes the tools and prevents admission and native
probes; read-only ownership inspection and durable recovery still run for previous reservations.
They are never rerun automatically: a task may already have pushed commits or opened a PR. Review its
workspace and publication evidence before submitting a fresh approval. None/stopped process ownership
releases its slot. A read-only inspection that proves the recorded group stopped also permits release;
a missing leader by itself is insufficient. Pending launch without PID/birth metadata, live owned
members, PID reuse or unreadable process state retains the reservation and blocks new Coder admission.
The rest of the assistant can remain available. A second daemon restart does not clear uncertainty.

For operator recovery:

1. Stop the daemon using the service commands in [INSTALL.md](INSTALL.md#4-running-as-a-service).
   Inspect the retained job and its `process_receipt_json` in `coder_jobs` under the selected state
   root's `claw.sqlite`; record the job UUID, phase, host boot ID, PID/PGID and birth identity.
   Preserve the job's private directory at `<state-root>/coder/jobs/<UUID>/` and inspect its work.
2. Compare the receipt with current host/process evidence. Terminate only processes whose ownership
   you have identified; a matching numeric PID or PGID alone is insufficient because IDs are reused.
   Do not signal an unrelated process or assume an absent leader means its group is empty.
3. Once the recorded group is verified empty, start the daemon again; Coder may remain disabled.
   Read-only startup reconciliation records stopped ownership and releases the existing terminal
   reservation without a second notice.
   If a crash happened between spawn and receipt persistence and ownership cannot be established,
   restart the host: a changed boot ID proves that the old-boot processes cannot survive.

Do not delete/forget job rows or manually reset reservations to bypass recovery. If the pending launch
receipt itself is missing or storage is unreadable, retain the state root and diagnose the storage
failure; no process identity can safely be invented. Process-event or terminal/outbox write failures
are unhealthy service outcomes and retain reservations without claiming a completion was delivered.
A failed protocol-file deletion can coexist with proved stopped processes: it remains a visible job
cleanup diagnostic, while process ownership determines whether a reservation can be released.

### Background completion acceptance

Run the complete owner-DM path without native inference or publication:

```bash
swift test --filter CoderDoneWhenTests
```

This scenario uses the real router, durable approval, Coder service, SQLite stores and outbox
dispatcher with scripted LLM, native backend and Telegram boundaries. After approval it holds the
backend, observes an ordinary reply in the same conversation, then releases the backend and verifies
the saved result and automatic completion delivery to the authenticated origin without another LLM
turn. Replaying the outbox wake keeps one completion row; failed network delivery retains the
existing at-least-once retry semantics.

### Live validation recorded on 2026-09-07

**The required native-denial evidence gap (V1) is closed.** The first supervised attempt on
2026-09-06 at 22:00 UTC remains historically inconclusive: its retained evidence lacked a refusal
tied to the requested command. One later authorized native job at 23:09:51–23:10:26 UTC supplied
the exact touch-command rejection from native `codex_core::tools::router` stderr. This establishes
native execpolicy denial; the worker's wording does not establish a separate Guardian decision.
Both attempts occurred on September 7 in Europe/Istanbul.

The later run used actual CoderService, CodexBackend and GRDB under a temporary `gui/502`
LaunchAgent on macOS 26.6.2 as `jetbrains` (UID 502), with Codex CLI 0.153.4, default
`/Users/jetbrains/.codex` and no named profile. The unchanged installed `run-clawd.sh` loaded a
separate `CLAW_ENV_FILE` containing the explicit PATH candidate recorded in the audit. That concrete
recipe passed local Codex login, native execution, and `gh` keyring/authenticated API checks.
The first service's default PATH could not resolve Codex, `gh` or Node; the tested candidate was
never installed into production configuration. Production enablement and deployment were excluded,
so this is no claim that the current installed service configuration is ready.

The job persisted failed/permission with one new completion outbox row at its fixture-approved
origin, retained the exact file contents, and released its reservation after owned work stopped.
A transparent observer was the selected executable and approval identity; it forwarded the real
CLI's production argv, schema, environment and finite stdin in the same process group. No Telegram
network delivery ran in the live probe; the deterministic acceptance above owns that boundary.
Independent evidence review passed. The unique rule, LaunchAgent and private controls/protocol files
were removed, all recorded owned groups were empty, and service shutdown joined.

The original foreground cancellation harness passed through the actual service, native backend,
process group and SQLite store with a harmless long-running external CLI fixture: its descendant
stopped, work remained, and both the N=1 capacity slot and checkout reservation were reused.
This was not paid inference cancellation. Historical draft PR #182 remains the publication baseline;
the service checks created no new push or PR. Exact recipes, evidence and review/validation closure
are in the [resumed evidence append](research/coder-capability-audit-2026-09-06.md#11-resumed-validation-and-final-review-closure).
