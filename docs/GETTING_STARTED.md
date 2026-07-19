# Getting Started

From nothing to a running assistant that answers you in Telegram. Every step shows the
command and what success looks like.

## What you need

- **A machine that stays on.** An Apple Silicon Mac (macOS 15 or newer; voice
  transcription and the code sandbox need macOS 26) or a Linux box with `libsqlite3-0`.
- **A Telegram account.**
- **LLM access.** Either an OpenAI-compatible endpoint with an API key (Anthropic,
  OpenAI, OpenRouter, or a local server), or a ChatGPT subscription (step 8).

Install `clawd` first: release binary or source build, both covered in the
[README](../README.md#install). The steps below assume `clawd` is on your `PATH`.

## 1. Create your bot

Open [@BotFather](https://t.me/BotFather) in Telegram, send `/newbot`, pick a name and a
username. BotFather replies with a token like `123456789:AAF...`. Copy it; that token is
the identity of your bot, so treat it like a password.

## 2. Configure

```bash
mkdir -p ~/.swift-claw
cp .env.example ~/.swift-claw/clawd.env
chmod 600 ~/.swift-claw/clawd.env
```

Edit `~/.swift-claw/clawd.env` and set four values:

- `CLAW_TELEGRAM_BOT_TOKEN`: the BotFather token.
- `CLAW_LLM_BASE_URL`: your provider's OpenAI-compatible endpoint,
  e.g. `https://api.anthropic.com/v1`.
- `CLAW_LLM_MODEL`: the model id, e.g. `claude-sonnet-4-6`.
- `CLAW_LLM_API_KEY`: the provider key (leave blank for local servers without auth).

Everything else has a working default. `clawd` never loads this file on its own; you
source it into the shell before each command:

```bash
set -a && source ~/.swift-claw/clawd.env && set +a
```

## 3. Seal your secrets

```bash
clawd secrets seal
```

This encrypts the bot token and API keys into `~/.swift-claw/secrets.enc` with a key in
`~/.swift-claw/secret.key` (mode 0600). Afterwards, delete or blank the
`CLAW_TELEGRAM_BOT_TOKEN`, `CLAW_LLM_API_KEY`, and `CLAW_SEARCH_API_KEY` lines in
`clawd.env`; the daemon now reads them from the encrypted store, and refuses to fall
back to plaintext if the store is present but broken.

Skipping this step works for a first try. The daemon then uses the plaintext env values
and warns on every boot.

## 4. Health check

```bash
clawd doctor
```

Healthy output shows `OK` on the `config` row and `backend=encrypted` on the `secrets`
row (`backend=env (WARN: plaintext)` if you skipped sealing). Doctor also probes the
database, Telegram connectivity (`getMe`), and the optional tool backends.
`clawd doctor --check-config` validates config and secrets without touching the network;
`--json` prints a machine-readable report.

## 5. Run and say hello

```bash
clawd run
```

DM your bot in Telegram. Because the allowlist is still empty, it answers:

> This is a private bot. Your Telegram user ID is 12345678. Ask the owner to add it to the allowlist.

That number is you. Stop the daemon (Ctrl-C), set it in `clawd.env`:

```bash
CLAW_ALLOWLIST=12345678
```

Re-source the env file, start `clawd run` again, and send another message. This time
the model answers, streamed into the chat as a growing draft. You have a working agent.

Two commands to know from day one: `/stop` cancels the current turn, `/new` starts a
fresh session.

## 6. Make it yours

Persona, behavior rules, and your profile live in Markdown files under
`~/.swift-claw/workspace/`. Start with `SOUL.md` for personality and `USER.md` for who
you are. [CUSTOMIZATION.md](CUSTOMIZATION.md) covers all of them, plus the environment
knobs for budgets, schedules, voice locales, and the code sandbox.

## 7. Run it as a service

For an assistant that survives reboots and logouts, install `clawd` under launchd
(macOS) or systemd (Linux). [deploy/README.md](../deploy/README.md) has the unit files
and the three commands per platform.

## 8. Optional: ChatGPT subscription instead of an API key

```bash
clawd auth login
```

completes a device-code login, discovers eligible models, and prints the exact
`CLAW_LLM_MODEL=openai-chatgpt/<model>` value to paste into `clawd.env`. On that route
`CLAW_LLM_BASE_URL` and `CLAW_LLM_API_KEY` are unused; the credential lives encrypted in
the state root. This route is unofficial and vendor-dependent; details and caveats in
[LOCAL_DEV.md](LOCAL_DEV.md#chatgpt-subscription-auth).

## Troubleshooting

- **Exit codes are diagnostic:** 10 invalid config, 11 secret loading failed, 12 another
  instance holds the lock, 13 storage error. `clawd doctor` explains the specifics.
- **The bot ignores you:** confirm your numeric ID is in `CLAW_ALLOWLIST` and that you
  restarted after changing it; the allowlist is seeded at boot.
- **A second daemon won't start:** by design. One `clawd` per state root, enforced with
  a file lock.
- **Telegram reports a 409 conflict:** another process is long-polling the same bot
  token, usually a forgotten instance on another machine.
- **Voice notes get a canned refusal:** voice transcription needs macOS 26; on Linux and
  older macOS the feature is off.
