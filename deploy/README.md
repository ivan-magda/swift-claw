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
