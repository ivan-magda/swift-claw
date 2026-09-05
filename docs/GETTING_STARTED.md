# Getting Started

From nothing to a running assistant that answers you in Telegram.

## What you need

- **A machine that stays on.** A Mac on macOS 15 or newer, or a Linux box with
  `libsqlite3-0`. Voice transcription needs macOS 26, and the code sandbox needs macOS 26
  on Apple Silicon; everything else runs anywhere.
- **A Telegram account.**
- **LLM access.** Either an OpenAI-compatible endpoint with an API key (Anthropic,
  OpenAI, OpenRouter, or a local server), or a ChatGPT subscription.

Install `clawd` first: the install script, a manual release download, or a source build,
all covered in [INSTALL.md](INSTALL.md). The steps below assume `clawd` is on your `PATH`.

**On a ChatGPT subscription?** Do [step 8](#8-chatgpt-subscription-instead-of-an-api-key)
right after step 2, before you start the daemon. Step 8 gives you the `CLAW_LLM_MODEL`
value that every later step needs, and `clawd auth login` will not start while the daemon
holds the state-root lock.

## 1. Create your bot

Open [@BotFather](https://t.me/BotFather) in Telegram, send `/newbot`, pick a name and a
username. BotFather replies with a token like `123456789:AAF...`. Copy it; that token is
the identity of your bot, so treat it like a password.

## 2. Configure

**Installed with the script?** `~/.swift-claw/clawd.env` is already in place — the
script installed the verified template on first run. Skip to editing it below.

**Manual install:** your shell executes this file with `source`, so use the copy that
ships with the release you verified rather than fetching one over the network:

```bash
mkdir -p -m 700 ~/.swift-claw
install -m 600 clawd.env.example ~/.swift-claw/clawd.env    # from your download directory
```

`clawd.env.example` is a release asset covered by `SHA256SUMS`, so the checksum step from
[INSTALL.md](INSTALL.md#2-manual-install) already verified it. From a source checkout, use
`install -m 600 .env.example ~/.swift-claw/clawd.env` instead.

Edit `~/.swift-claw/clawd.env` and set four values:

- `CLAW_TELEGRAM_BOT_TOKEN`: the BotFather token.
- `CLAW_LLM_BASE_URL`: your provider's OpenAI-compatible endpoint,
  e.g. `https://api.anthropic.com/v1`.
- `CLAW_LLM_MODEL`: the model id, e.g. `claude-sonnet-4-6`.
- `CLAW_LLM_API_KEY`: the provider key (leave blank for local servers without auth).

Nothing else is required. To have clawd finish a turn on a second model when the first one
cannot answer, set `CLAW_LLM_FALLBACK_MODEL`; it stays off until you do.
[CUSTOMIZATION.md](CUSTOMIZATION.md#a-second-route-to-fall-back-to) covers that route, what
it costs you, and what clawd tells you when it switches.

On a ChatGPT subscription, clear the prefilled `CLAW_LLM_BASE_URL` and `CLAW_LLM_API_KEY`,
then get your `CLAW_LLM_MODEL` value from
[step 8](#8-chatgpt-subscription-instead-of-an-api-key) now. Every later step needs it: a
plain model id with an empty base URL fails config validation.

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
`~/.swift-claw/secret.key` (mode 0600).

Sealing also blanks every plaintext secret line in `clawd.env` itself
(`CLAW_TELEGRAM_BOT_TOKEN`, `CLAW_LLM_API_KEY`, `CLAW_SEARCH_API_KEY`, and
`CLAW_LLM_FALLBACK_API_KEY`), and tells you what it changed (`--no-scrub` keeps them;
before v0.2.0, blank them yourself). The daemon now reads the secrets from the encrypted
store, and refuses to fall back to plaintext if the store is present but broken.

Sourcing the file again does not undo the export: your current shell still holds the
values it read before sealing blanked them. Open a fresh shell and source the sanitized
file there:

```bash
set -a && source ~/.swift-claw/clawd.env && set +a
```

Skipping this step works for a first try. The daemon then uses the plaintext env values
and warns on every boot. (If you did step 8 first, `clawd auth login` already sealed the
state root, so the encrypted backend is in force and there is no plaintext fallback.)

## 4. Health check

```bash
clawd doctor --check-config
```

Healthy output shows `OK` on the `config` row and `backend=encrypted` on the `secrets`
row (`backend=env (WARN: plaintext)` if you skipped sealing).

Use `--check-config` until you have allowlisted yourself in step 5. The full `clawd
doctor` also checks the database, and with an empty allowlist the `allowlist.owners` row
fails and the command exits 1. Once your ID is in `CLAW_ALLOWLIST`, run the full check:

```bash
clawd doctor          # adds database, Telegram getMe, and tool-backend probes
clawd doctor --json   # same checks, machine-readable
```

The full check includes a `context.skills` row. It reports accepted and rejected skill
counts plus `fits_cap`, which tells you whether the complete skill index fits its absolute
context allowance. A rejected skill or `fits_cap=false` makes the row fail. Telegram
`/status` shows the same row after the daemon starts.

## 5. Run and say hello

```bash
clawd run
```

Send `/start` to your bot in Telegram. Because the allowlist is still empty, it answers:

> This is a private bot. Your Telegram user ID is 12345678. To authorize it, the owner
> adds this line to clawd.env and restarts clawd:
> CLAW_ALLOWLIST=12345678

(v0.2.0+; older releases print the ID in prose without the pasteable line.)

Only `/start` gets that reply. Any other message from a non-allowlisted sender gets a
bare "Sorry, this is a private bot." with no ID, so `/start` is how you learn the number.

That number is you. Stop the daemon (Ctrl-C) and paste the shown line into `clawd.env`:

```bash
CLAW_ALLOWLIST=12345678
```

Re-source the env file, start `clawd run` again, and send another message. This time
the model answers, and clawd streams the reply in as a growing draft.

Two commands to know from day one: `/stop` cancels the current turn, `/new` starts a
fresh session.

## 6. Make it yours

Persona, behavior rules, and your profile live in Markdown files under
`~/.swift-claw/workspace/`. The daemon creates that directory empty and ships no
templates, so create the files yourself:

```bash
cat > ~/.swift-claw/workspace/SOUL.md <<'EOF'
Answer briefly. Skip pleasantries. Say when you are unsure.
EOF

cat > ~/.swift-claw/workspace/USER.md <<'EOF'
I live in Berlin and work as an iOS developer.
EOF
```

The agent picks them up on the next turn.

Write a procedure you want followed on a particular kind of task into
`skills/<name>/SKILL.md`, one directory per skill. The agent sees a one-line summary of
each and pulls up the full text when the task matches:

```bash
mkdir -p ~/.swift-claw/workspace/skills/weekly-review
cat > ~/.swift-claw/workspace/skills/weekly-review/SKILL.md <<'EOF'
---
name: weekly-review
description: How to run the Friday review — which projects to check and what to report.
---

Go through the open projects newest first. For each one, ...
EOF
```

Send `/skills` to the bot. The Accepted section should contain
`weekly-review`; the Rejected section explains any frontmatter, naming, duplicate, or
workspace-boundary problem that kept a skill out.

[CUSTOMIZATION.md](CUSTOMIZATION.md) covers every file and its trust tier, the skill
authoring rules, the environment knobs for budgets, schedules, voice locales, and the
code sandbox, and how to [connect MCP servers](CUSTOMIZATION.md#mcp-servers) so their
tools show up in chat.

### Let scheduled jobs learn from feedback

Set `CLAW_LEARNING_ENABLED=true` in `clawd.env`, reload the file and restart the daemon.
Learning is off by default. Once enabled, clawd evaluates eligible completed scheduled
runs and offers feedback buttons on their results. Tap **Correct it** and answer the prompt
to describe what should change; one correction can produce a candidate lesson set and start
a trial. Two positive trial runs can promote it; one negative run ends the trial.

These extra model calls use your configured route and count toward the global and proactive
budgets. Send `/learning` to inspect the state, or `/learning <jobId>` for a job's lessons
and rollback control. [Scheduled learning](CUSTOMIZATION.md#scheduled-learning) covers
candidate edits, reset, fixed trial limits and retention.

## 7. Keep it running

To restart `clawd` after a crash and start it on login, run it under launchd (macOS) or
systemd (Linux). A healthy `clawd doctor` ends by printing the exact start command for
your machine — run that.

[INSTALL.md section 4](INSTALL.md#4-running-as-a-service) covers both layouts (script
install and manual `/usr/local/bin`), plus the linger/auto-login notes for a machine
that should stay on after you log out, log locations, and the exit codes.

## 8. ChatGPT subscription instead of an API key

This route replaces `CLAW_LLM_BASE_URL` and `CLAW_LLM_API_KEY`. **Stop `clawd` first**:
logging in takes the same state-root lock the daemon holds, and while the daemon runs,
`clawd auth login` exits with "clawd is running for this state root."

- Foreground: Ctrl-C.
- macOS: `launchctl bootout gui/$(id -u)/com.ivanmagda.swift-claw`
- Linux: `systemctl --user stop swift-claw.service`

```bash
clawd auth login
```

This completes a device-code login, discovers eligible models, and prints the exact
`CLAW_LLM_MODEL=openai-chatgpt/<model>` value to paste into `clawd.env`. On that route
`CLAW_LLM_BASE_URL` and `CLAW_LLM_API_KEY` are unused; the credential lives encrypted in
the state root.

If clawd cannot read the model list, `clawd auth login` still succeeds and stores the
credential, but prints the assignment with `<model>` left as a literal placeholder. Paste that
verbatim and config validation rejects it. Substitute a real model slug, for example
`CLAW_LLM_MODEL=openai-chatgpt/gpt-5.4`, or run `clawd auth login` again once the network
settles.

Paste the value into `clawd.env`. If you are switching an existing installation, also
clear `CLAW_LLM_STRUCTURED_OUTPUT`: this route accepts only `off`, and any other value
fails config validation with exit 10. Then:

- **Setting up for the first time?** Go back to [step 3](#3-seal-your-secrets) and continue
  through the guide. Do not start the daemon yet; the remaining steps need the state root
  to themselves.
- **Already had clawd running?** Start it again: `clawd run`, or
  `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.ivanmagda.swift-claw.plist` /
  `systemctl --user start swift-claw.service`.

This route is unofficial and vendor-dependent; details and caveats in
[LOCAL_DEV.md](LOCAL_DEV.md#chatgpt-subscription-auth).

## Troubleshooting

- **Exit codes are diagnostic:** 10 invalid config, 11 secret loading failed, 12 another
  instance holds the lock, 13 storage error. `clawd doctor` explains the specifics.
- **The bot ignores you:** confirm your numeric ID is in `CLAW_ALLOWLIST` and that you
  restarted after changing it; the daemon seeds the allowlist at boot.
- **You cannot find your Telegram ID:** send `/start`, not an ordinary message.
- **Someone you removed can still talk to the bot:** `CLAW_ALLOWLIST` seeds the database
  and never deletes from it. Revoking takes a row deletion; see
  [CUSTOMIZATION.md](CUSTOMIZATION.md#everything-else).
- **A second daemon won't start:** by design. One `clawd` per state root, enforced with
  a file lock. `clawd auth login`, `clawd secrets seal`, and `clawd mcp set-token` /
  `clear-token` take the same lock, so stop the daemon before running them.
- **Telegram reports a 409 conflict:** another process is long-polling the same bot
  token, usually a forgotten instance on another machine.
- **Voice notes get a canned refusal:** voice transcription needs macOS 26; on Linux and
  older macOS the feature is off.
- **clawd says your model can't look at images:** send `/new` first — the photo stays in
  the conversation otherwise, and every question after it gets the same refusal. Photos
  need a vision-capable `CLAW_LLM_MODEL`; switch models, or set `CLAW_IMAGE_INPUT=false`
  to stop sending them.
