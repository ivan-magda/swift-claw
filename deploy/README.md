# deploy/

**Conference deployment:** start with the standalone Russian
[CONFERENCE.md](../docs/CONFERENCE.md). It builds `feature/conference-coding-challenge` /
PR #199 on a fresh Mac without merging into `main`, then creates a dedicated binary,
state root and LaunchAgent. Use its service setup and update commands for the conference branch.

Service files shipped with every release:

- `run-clawd.sh` — wrapper that sources `clawd.env` and execs `clawd run`.
- `com.ivanmagda.swift-claw.plist` — launchd LaunchAgent (macOS).
- `swift-claw.service` — systemd user service (Linux).

Install, start, update, and uninstall instructions — for both the scripted
`~/.swift-claw` layout and the manual `/usr/local/bin` layout — live in
[docs/INSTALL.md](../docs/INSTALL.md).

Exit codes are diagnostic:

| Code | Meaning                                    |
| ---- | ------------------------------------------ |
| 10   | invalid config                             |
| 11   | secret loading failed                      |
| 12   | another instance holds the state-root lock |
| 13   | storage error                              |

## Optional Coder in the service account

Enabling `CLAW_CODER_ENABLED=true` adds native Codex background jobs in owner DMs and configured
group topics. Install Codex, Git (`/usr/bin/git` for preparation) and, for GitHub tasks, `gh`
separately. PRs require that account's configured clone/push/PR rights. The installer does not
provision dependencies or credentials.

The wrapper already sources `clawd.env`; `clawd` does not automatically load `.env`. Run `clawd coder
setup` from a terminal where Codex and its interpreter/toolchain work. It checks the existing Coder
selection, then records that terminal's absolute path entries in the Coder-only `CLAW_CODER_PATH` and
enables Coder. It does not install dependencies, import credentials, edit shell startup files or
restart the service. The daemon's global PATH is unchanged.

Restart the real service and inspect Telegram `/status`. Verify the effective directory count in
`coder.path`, the resolved Codex and `gh` executables, Node when present, and authentication
under the launchd/systemd account. Also validate HOME, `CODEX_HOME`/`CLAW_CODER_CONFIG_HOME`, selected profile,
`GH_CONFIG_DIR` and keyring access. Setup's terminal checks are not proof of service authorization.
Rerun it after an nvm or other tool-path change. Codex owns its auth; `clawd auth` manages only the
conversational route.

For group Coder, keep the group deployment on a separate nonpersonal state root and make the bot a
group administrator. Every approval tap uses a fresh Telegram `getChatMember` lookup; Telegram only
guarantees checks for other users when the bot is an administrator. Lookup failure leaves the approval
pending. Any current participant may decide the original prompt, while only its requester may inspect
or cancel the job from that same topic.

`clawd doctor --check-config` runs no Codex probes. With Coder enabled, full doctor adds bounded local
compatibility/status checks; selected-profile auth remains explicitly unverified when the CLI cannot
inspect it. Diagnostics perform no inference, credential refresh, repository or PR creation.
Coder shutdown cancels and joins native work before dependent teardown; unresolved ownership retains reservations
for conservative recovery. Disabling Coder removes its tools and native probes but still reconciles
earlier jobs on restart; full doctor and daemon health keep their reservations and uncertainty visible.
See [INSTALL.md](../docs/INSTALL.md#coder-prerequisites) and
[LOCAL_DEV.md](../docs/LOCAL_DEV.md#coder-background-lifecycle-and-recovery).

For the separate [conference challenge profile](../docs/CONFERENCE.md), use a dedicated
nonpersonal service account, state root and GitHub bot-user token. Configure `CLAW_GROUP_CHATS`
and make the bot a group administrator. The profile serves those groups/topics only; private messages
are ignored and each proposal requires its author's confirmation. Its Coder config home must
resolve within that state root; the supervisor publishes draft PRs and removes the publication
credential from Coder's environment. Follow the conference runbook before opening participant access.
