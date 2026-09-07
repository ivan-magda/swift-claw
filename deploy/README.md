# deploy/

Service files shipped with every release:

- `run-clawd.sh` — wrapper that sources `clawd.env` and execs `clawd run`.
- `com.ivanmagda.swift-claw.plist` — launchd LaunchAgent (macOS).
- `swift-claw.service` — systemd user service (Linux).

Install, start, update, and uninstall instructions — for both the scripted
`~/.swift-claw` layout and the manual `/usr/local/bin` layout — live in
[docs/INSTALL.md](../docs/INSTALL.md).

Exit codes are diagnostic:

| Code | Meaning |
|---|---|
| 10 | invalid config |
| 11 | secret loading failed |
| 12 | another instance holds the state-root lock |
| 13 | storage error |

## Optional Coder in the service account

Enabling `CLAW_CODER_ENABLED=true` adds native Codex background jobs in owner DMs. Install Codex,
Git (`/usr/bin/git` for preparation) and, for GitHub tasks, `gh` separately. PRs require that account's
configured clone/push/PR rights. The installer does not provision dependencies or credentials.

The wrapper already sources `clawd.env`; put the deliberate PATH and six Coder settings there.
`clawd` does not automatically load `.env`. Include any Codex interpreter/toolchain in PATH and
validate HOME, `CODEX_HOME`/`CLAW_CODER_CONFIG_HOME`, selected profile, `GH_CONFIG_DIR` and login/keyring
access under the actual launchd/systemd user. Shell access is not proof of service authorization.
Codex owns its auth; `clawd auth` manages only the conversational route.

`clawd doctor --check-config` runs no Codex probes. With Coder enabled, full doctor adds bounded local
compatibility/status checks; selected-profile auth remains explicitly unverified when the CLI cannot
inspect it. Diagnostics perform no inference, credential refresh, repository or PR creation.
Coder shutdown cancels and joins native work before dependent teardown; unresolved ownership retains reservations
for conservative recovery. Disabling Coder removes its tools and native probes but still reconciles
earlier jobs on restart; full doctor and daemon health keep their reservations and uncertainty visible.
See [INSTALL.md](../docs/INSTALL.md#coder-prerequisites) and
[LOCAL_DEV.md](../docs/LOCAL_DEV.md#coder-background-lifecycle-and-recovery).
