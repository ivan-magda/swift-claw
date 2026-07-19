# swift-claw

[![CI](https://github.com/ivan-magda/swift-claw/actions/workflows/ci.yml/badge.svg)](https://github.com/ivan-magda/swift-claw/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/ivan-magda/swift-claw)](../../releases/latest)
[![Swift 6.3](https://img.shields.io/badge/Swift-6.3-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20Linux-blue)](#install)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

**Your always-on personal AI assistant in Telegram. One pure-Swift daemon on hardware you own.**

`clawd` pairs a private Telegram bot with the LLM of your choice. It remembers what you
tell it, runs scheduled and proactive tasks, and executes tools behind an approval gate.
Everything it keeps lives in one directory on your own machine: a SQLite database,
encrypted secret envelopes, and Markdown files you can edit by hand.

## Features

- **A real Telegram chat.** Answers stream in as live message drafts. `/stop` cancels a
  turn, `/new` starts a fresh session, and voice notes transcribe on-device (macOS 26).
- **Durable memory.** Facts you confirm persist in SQLite with full-text recall, next to
  workspace Markdown files that hold your profile, notes, and daily logs.
- **Proactive, on your clock.** "Every weekday at 07:00" schedules fire once per
  occurrence across restarts and DST changes, and an opt-in heartbeat respects quiet hours.
- **Tools behind a policy engine.** `web_fetch` sits behind an SSRF gate; writes and code
  execution wait for an explicit tap-to-approve in Telegram. Policy lives in code, and
  inbound content is treated as data, never as instructions.
- **Sandboxed code execution.** Untrusted code runs in a fresh disposable VM per request
  (macOS 26 arm64, off by default).
- **Bring your own model.** Any OpenAI-compatible endpoint works, and `clawd auth login`
  can run an eligible model on a ChatGPT subscription.
- **One binary.** Swift 6 with strict concurrency, from the Telegram long-poll down to SQLite.

## Install

Releases carry two binaries: `clawd-macos-arm64` (Apple Silicon) and `clawd-linux-x86_64`.
On any other architecture, build from source below.

From the [latest release](../../releases/latest), download **the binary for your platform,
`SHA256SUMS`, and `clawd.env.example`** (the config template, used in the quick start).
Then verify and install from your download directory:

```bash
cd ~/Downloads
ASSET=clawd-macos-arm64                                 # Linux: clawd-linux-x86_64

shasum -a 256 --ignore-missing -c SHA256SUMS            # Linux: sha256sum --ignore-missing -c SHA256SUMS
sudo install -m755 "$ASSET" /usr/local/bin/clawd
```

`--ignore-missing` checks only the files you actually downloaded. Every one of them must
print `OK` and the command must exit 0; anything else means stop.

Every binary also carries a build provenance attestation. If you have the
[GitHub CLI](https://cli.github.com) installed and logged in (`gh auth login`), verify it:

```bash
gh attestation verify "$ASSET" -R ivan-magda/swift-claw
```

- **macOS:** Gatekeeper blocks the unsigned binary on first run. Clear it:
  `sudo xattr -d com.apple.quarantine /usr/local/bin/clawd`.
  On a Mac without Homebrew, create the install directory first:
  `sudo mkdir -p /usr/local/bin`.
- **Linux:** the binary links the system SQLite: `sudo apt-get install -y libsqlite3-0`.

Or build from source with a Swift 6.3 toolchain. On Linux, install the SQLite headers
first (`sudo apt-get install -y libsqlite3-dev`); the runtime package alone will not link:

```bash
git clone https://github.com/ivan-magda/swift-claw.git && cd swift-claw
swift build -c release
sudo install -m755 .build/release/clawd /usr/local/bin/clawd
```

From a source checkout the config template is `.env.example` in the repository root, and
the service files are under `deploy/`.

## Quick start

Create a bot with [@BotFather](https://t.me/BotFather) (`/newbot`) and copy its token. Then:

Download `clawd.env.example` from the same release as your binary, verify it against
`SHA256SUMS` alongside the binary, and use it as your config:

```bash
# 1. Install the verified template.
mkdir -p -m 700 ~/.swift-claw
install -m 600 clawd.env.example ~/.swift-claw/clawd.env
```

Your shell runs this file with `source`, so take it from the checksummed release rather
than an unverified copy.

**Now edit `~/.swift-claw/clawd.env`** and set the BotFather token plus your provider's
`CLAW_LLM_BASE_URL`, `CLAW_LLM_MODEL`, and `CLAW_LLM_API_KEY`. The template ships with
placeholder values that will not work. Then:

```bash
# 2. Load the config and encrypt your secrets at rest.
set -a && source ~/.swift-claw/clawd.env && set +a
clawd secrets seal

# 3. Sealing copies the secrets out; it does not edit the file. Delete the
#    CLAW_TELEGRAM_BOT_TOKEN, CLAW_LLM_API_KEY, and CLAW_SEARCH_API_KEY lines
#    from ~/.swift-claw/clawd.env yourself.
```

Open a fresh shell so the deleted secrets leave your environment, then load the remaining
config and start the daemon:

```bash
set -a && source ~/.swift-claw/clawd.env && set +a
clawd doctor --check-config
clawd run
```

Now send `/start` to your bot. It replies with your numeric Telegram ID; put that in
`CLAW_ALLOWLIST` in `clawd.env`, re-source, and restart. Your next message gets a real
answer. (Only `/start` reveals the ID: any other message from a stranger gets a bare
refusal.)

Running on a ChatGPT subscription instead of an API key? Do
[step 8](docs/GETTING_STARTED.md#8-chatgpt-subscription-instead-of-an-api-key)
of the walkthrough before you start the daemon. The full guide, including
troubleshooting, is in [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md).

## Security model

swift-claw assumes the person who runs it is the only person it serves.

- **Default-deny.** Only allowlisted Telegram IDs get a conversation. Everyone else is
  refused, and `/start` returns the sender's own numeric ID so you can allowlist them.
  `CLAW_ALLOWLIST` only ever adds: revoking an ID means deleting its row from the database
  ([details](docs/CUSTOMIZATION.md#everything-else)).
- **Secrets encrypted at rest.** `clawd secrets seal` wraps the bot token and API keys in
  an AES-GCM envelope. Plaintext env secrets remain available as a dev fallback that
  warns on every boot.
- **Approvals you can trust.** File writes, memory writes, and code execution always
  suspend into a durable state machine until you tap Approve in Telegram. A forged or
  third-party callback cannot approve, and pending approvals expire to deny.
- **Prompt injection contained.** Messages, web content, tool output, and stored memory
  enter the context as untrusted data. Once a session has both ingested untrusted content
  and pulled your private files into context, fetching an arbitrary URL also needs your
  approval. Your LLM and search providers are pinned destinations that clawd cannot be
  redirected away from.

The full model is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (§12). To report a
vulnerability, see [SECURITY.md](SECURITY.md).

## Customize your agent

Persona and behavior live in Markdown files under `~/.swift-claw/workspace/`:

| File | Shapes | Trust |
|---|---|---|
| `SOUL.md` | Personality and tone | System prompt |
| `AGENTS.md` | Behavior rules | System prompt |
| `TOOLS.md` | When and how to use tools | System prompt |
| `USER.md` | Who you are | Untrusted, labeled |
| `HEARTBEAT.md` | The proactive heartbeat checklist | Heartbeat runs only |

Runtime knobs are environment variables: the model route (`CLAW_LLM_MODEL`), USD
budgets, schedules and quiet hours, voice locales, sandbox limits.
[`.env.example`](.env.example) documents every variable;
[docs/CUSTOMIZATION.md](docs/CUSTOMIZATION.md) is the guide.

## Documentation

| You want to | Read |
|---|---|
| Set it up end to end | [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md) |
| Make it yours | [docs/CUSTOMIZATION.md](docs/CUSTOMIZATION.md) |
| Run it as a service | [deploy/README.md](deploy/README.md) |
| Develop and test locally | [docs/LOCAL_DEV.md](docs/LOCAL_DEV.md) |
| Understand the design | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| Report a vulnerability | [SECURITY.md](SECURITY.md) |

## Contributing

Contributions are welcome. Open an issue to discuss what you have in mind before
sending a pull request; [CONTRIBUTING.md](CONTRIBUTING.md) has the details and the
lint/test gate.

## License

[MIT](LICENSE) © Ivan Magda
