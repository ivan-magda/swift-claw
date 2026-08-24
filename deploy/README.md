# deploy/

Service files shipped with every release:

- `run-clawd.sh` — wrapper that sources `clawd.env` and execs `clawd run`.
- `com.ivanmagda.swift-claw.plist` — launchd LaunchAgent (macOS).
- `swift-claw.service` — systemd user service (Linux).

Neither unit confines the daemon: `clawd` runs with the installing user's own privileges.
That is what an approved [host shell command](../docs/CUSTOMIZATION.md#host-shell-commands)
gets when `CLAW_BASH_ENABLED=true`, so pick the account accordingly. The command drops `CLAW_*`
variables but inherits the unit's other credentials and `SSH_AUTH_SOCK`; keep that environment
minimal.

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
