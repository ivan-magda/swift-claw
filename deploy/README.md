# Deploying clawd

## Install

**Option A (release binary, recommended).** Download `clawd-<platform>` and `SHA256SUMS` from the [latest release](../../../releases/latest). The same release ships `clawd.env.example` and the unit files below, all under that one manifest.

```bash
shasum -a 256 --ignore-missing -c SHA256SUMS &&        # Linux: sha256sum --ignore-missing -c SHA256SUMS
  sudo install -m755 clawd-<platform> /usr/local/bin/clawd
```

`--ignore-missing` checks only what you downloaded. Every listed file must print `OK`, and the `&&` stops the install if any does not. To also check build provenance, run `gh attestation verify <binary> -R ivan-magda/swift-claw` (needs the GitHub CLI, logged in).

Platform notes:

- **macOS:** clear quarantine with `sudo xattr -d com.apple.quarantine /usr/local/bin/clawd`.
- **Linux:** install `libsqlite3-0`.

**Option B (build from source).**

1. `swift build -c release` → `sudo install -m755 .build/release/clawd /usr/local/bin/clawd`.
2. `cp .env.example ~/.swift-claw/clawd.env`, fill in the token + allowlist, `chmod 600 ~/.swift-claw/clawd.env`.
3. Verify: `clawd doctor` (config first, then DB/allowlist/connectivity).

## macOS (launchd)

- `sudo install -m755 deploy/run-clawd.sh /usr/local/bin/run-clawd.sh`
- `mkdir -p ~/Library/LaunchAgents && cp deploy/com.ivanmagda.swift-claw.plist ~/Library/LaunchAgents/`
- `launchctl load ~/Library/LaunchAgents/com.ivanmagda.swift-claw.plist`

## Linux (systemd, user service)

- `mkdir -p ~/.config/systemd/user && cp deploy/swift-claw.service ~/.config/systemd/user/`
- `systemctl --user enable --now swift-claw.service`
- `journalctl --user -u swift-claw -f`

Both units are per-user: they start at login, not at boot, and stop at logout. On Linux, `sudo loginctl enable-linger $USER` keeps the service alive across logout and starts it at boot. On macOS, enable automatic login for the account. A `/Library/LaunchDaemons` service instead runs as root, where `$HOME` is `/var/root` and `run-clawd.sh` cannot find `~/.swift-claw/clawd.env`, so `clawd` exits 10. If you take that path, set `UserName`, `CLAW_ENV_FILE`, and `CLAW_STATE_ROOT` in the plist.

A second `clawd` against the same state root refuses to boot (flock); a Telegram 409 is logged as critical. Distinct exit codes: 10 config, 11 secret, 12 already-running, 13 store.
