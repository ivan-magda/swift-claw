# Deploying clawd

1. `swift build -c release` → copy `.build/release/clawd` to `/usr/local/bin/clawd`.
2. `cp .env.example ~/.swift-claw/clawd.env`, fill in the token + allowlist, `chmod 600 ~/.swift-claw/clawd.env`.
3. Verify: `clawd doctor` (config first, then DB/allowlist/connectivity).

## macOS (launchd)

- `cp deploy/run-clawd.sh /usr/local/bin/ && chmod +x /usr/local/bin/run-clawd.sh`
- `cp deploy/com.ivanmagda.swift-claw.plist ~/Library/LaunchAgents/`
- `launchctl load ~/Library/LaunchAgents/com.ivanmagda.swift-claw.plist`

## Linux (systemd, user service)

- `cp deploy/swift-claw.service ~/.config/systemd/user/`
- `systemctl --user enable --now swift-claw.service`
- `journalctl --user -u swift-claw -f`

A second `clawd` against the same state root refuses to boot (flock); a Telegram 409 is logged as critical. Distinct exit codes: 10 config, 11 secret, 12 already-running, 13 store.
