<p align="center">
  <img
    src="docs/assets/branding/swift-claw-hero-dark-1400x700.png"
    alt="swift-claw — Your AI. Your machine. Always on."
    width="100%"
  />
</p>

<p align="center">
  <a href="https://github.com/ivan-magda/swift-claw/actions/workflows/ci.yml"><img src="https://github.com/ivan-magda/swift-claw/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="../../releases/latest"><img src="https://img.shields.io/github/v/release/ivan-magda/swift-claw" alt="Release"></a>
  <a href="https://swift.org"><img src="https://img.shields.io/badge/Swift-6.3-F05138?logo=swift&logoColor=white" alt="Swift 6.3"></a>
  <a href="#install"><img src="https://img.shields.io/badge/platforms-macOS%20%7C%20Linux-blue" alt="Platforms: macOS | Linux"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="License: MIT"></a>
</p>

**Your always-on personal AI assistant. One pure-Swift daemon on hardware you own.**

`clawd` pairs a private Telegram bot with the LLM of your choice. It remembers what you
tell it and runs scheduled and proactive tasks. Consequential tool calls wait for your
approval. Everything it keeps stays in one directory on your own machine: a SQLite
database, encrypted secret envelopes, and Markdown files you edit by hand.

## Features

- **A real Telegram chat.** Answers stream in as live message drafts. `/stop` cancels a
  turn, `/new` starts a fresh session, clawd transcribes voice notes on-device
  (macOS 26), and it looks at photos you send if your model can see them.
- **Durable memory.** Facts you confirm persist in SQLite, and clawd recalls them by
  importance and recency. Workspace Markdown files hold your profile, notes, and daily
  logs, and conversation history is full-text searchable.
- **Skills you write once.** A `skills/<name>/SKILL.md` file shows up in context as its name
  and one line about when to use it; when a task matches, clawd loads the body and follows
  your procedure instead of asking you to paste it again.
- **Proactive, on your clock.** "Every weekday at 07:00" schedules fire once per
  occurrence across restarts and DST changes, and an opt-in heartbeat respects quiet hours.
- **Tools behind a policy engine.** `web_fetch` sits behind an SSRF gate; writes and code
  execution wait for an explicit tap-to-approve in Telegram. clawd enforces policy in
  code and treats inbound content as data, never as instructions.
- **Sandboxed code execution.** Untrusted code runs in a fresh disposable VM per request
  (macOS 26 arm64, off by default).
- **Bring your own model.** Any OpenAI-compatible endpoint works, and `clawd auth login`
  can run an eligible model on a ChatGPT subscription.
- **One binary.** Swift 6 with strict concurrency, from the Telegram long-poll down to SQLite.

## The approval card

<p align="left">
  <img
    src="docs/assets/demo/card-deny.gif"
    alt="A request to write a file pauses in Telegram: the approval card shows the fully-resolved target path, the size, and a preview, with Approve and Deny buttons. The user taps Deny and clawd writes nothing."
    width="50%"
  />
</p>

A file write suspends the run until you answer. Every field on the card comes from the daemon's own
record of the action: the target path after symlink and `..` resolution, the size, and a preview of
the content. Tap Deny and clawd writes nothing.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/ivan-magda/swift-claw/main/install.sh | sh
```

Everything lands in `~/.swift-claw`, with no sudo. The script verifies every download
against the release checksums, stages the service files, and prints the next steps.
Pin a release with `curl … | CLAWD_VERSION=v0.2.0 sh`, read the
[script source](install.sh) first, or follow the manual route in
[docs/INSTALL.md](docs/INSTALL.md) (macOS 15+ arm64; Linux x86_64 with glibc 2.38+).

Or build from source with a Swift 6.3 toolchain (Linux needs `libsqlite3-dev`):

```bash
git clone https://github.com/ivan-magda/swift-claw.git && cd swift-claw
swift build -c release
sudo install -m755 .build/release/clawd /usr/local/bin/clawd
```

## Quick start

1. Get a bot token from [@BotFather](https://t.me/BotFather) (send `/newbot`).
2. Edit `~/.swift-claw/clawd.env`: set the token and your LLM provider
   (`CLAW_LLM_BASE_URL`, `CLAW_LLM_MODEL`, `CLAW_LLM_API_KEY`).
3. Load the config and encrypt your secrets at rest:
   `set -a && . ~/.swift-claw/clawd.env && set +a && clawd secrets seal`
4. Say hello once in the foreground: `clawd run`, then send `/start` to your bot. The
   refusal shows your numeric ID; set it as `CLAW_ALLOWLIST=<id>` in `clawd.env`, then
   Ctrl-C.
5. Check health and start the service:
   `set -a && . ~/.swift-claw/clawd.env && set +a && clawd doctor`, then run the start
   command doctor prints.

The full walkthrough, including the ChatGPT-subscription route and troubleshooting, is
in [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md).

## Security model

swift-claw assumes you are the only person it serves.

- **Default-deny.** Only allowlisted Telegram IDs get a conversation. clawd refuses
  everyone else, and answers `/start` with the sender's own numeric ID so you can
  allowlist them. `CLAW_ALLOWLIST` only ever adds, so revoking an ID means deleting its
  row from the database ([details](docs/CUSTOMIZATION.md#everything-else)).
- **Secrets encrypted at rest.** `clawd secrets seal` wraps the bot token and API keys in
  an AES-GCM envelope. Plaintext env secrets remain available as a dev fallback that
  warns on every boot.
- **Approvals are durable and unforgeable.** File writes, memory writes, and code
  execution suspend into a durable state machine until you tap Approve in Telegram. A
  forged or third-party callback cannot approve, and pending approvals expire to deny.
- **Prompt injection contained.** Messages, web content, tool output, and stored memory
  enter the context as untrusted data. Once a session has both ingested untrusted content
  and pulled your private files into context, fetching an arbitrary URL also needs your
  approval. clawd pins your LLM and search providers in config, and the model cannot
  redirect them.

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
| `skills/<name>/SKILL.md` | A procedure the agent loads when a task calls for it | Untrusted, labeled |

Runtime knobs are environment variables: the model route (`CLAW_LLM_MODEL`), an optional
fallback route (`CLAW_LLM_FALLBACK_MODEL`, off unless you set it), USD budgets, schedules
and quiet hours, voice locales, sandbox limits.
[`.env.example`](.env.example) documents every variable;
[docs/CUSTOMIZATION.md](docs/CUSTOMIZATION.md) is the guide.

## Documentation

| You want to | Read |
|---|---|
| Set it up end to end | [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md) |
| Install, update, or uninstall | [docs/INSTALL.md](docs/INSTALL.md) |
| Make it yours | [docs/CUSTOMIZATION.md](docs/CUSTOMIZATION.md) |
| Run it as a service | [docs/INSTALL.md](docs/INSTALL.md#4-running-as-a-service) |
| Develop and test locally | [docs/LOCAL_DEV.md](docs/LOCAL_DEV.md) |
| Understand the design | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| Report a vulnerability | [SECURITY.md](SECURITY.md) |

## Contributing

Contributions are welcome. Open an issue to discuss what you have in mind before
sending a pull request; [CONTRIBUTING.md](CONTRIBUTING.md) has the details and the
lint/test gate.

## License

[MIT](LICENSE) © Ivan Magda
