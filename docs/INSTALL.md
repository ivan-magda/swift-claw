# Install, update, or uninstall

Everything about getting the `clawd` binary on and off a machine. For first-run
configuration (bot token, secrets, allowlist), continue with
[GETTING_STARTED.md](GETTING_STARTED.md).

**Conference deployment:** follow the standalone Russian [CONFERENCE.md](CONFERENCE.md)
first. It builds `feature/conference-coding-challenge` / PR #199 directly on a fresh Mac,
without merging into `main`, and installs a dedicated binary, state root and LaunchAgent.
Use that guide's install and update commands for the conference branch. The release installer
below uses published assets and the personal assistant's layout.

## 1. Install

```bash
curl -fsSL https://raw.githubusercontent.com/ivan-magda/swift-claw/main/install.sh | sh
```

Pin a release instead of latest:

```bash
curl -fsSL https://raw.githubusercontent.com/ivan-magda/swift-claw/main/install.sh | CLAWD_VERSION=v0.2.0 sh
```

What the script does:

- Checks the platform: macOS 15+ on Apple Silicon, or Linux x86_64 with glibc 2.38+
  (anything else gets a build-from-source pointer, and the script installs nothing).
- Downloads the release binary, `SHA256SUMS`, the config template, `run-clawd.sh`, and
  the service unit for your platform.
- Verifies every download against `SHA256SUMS`; when the GitHub CLI is installed and
  logged in, it also verifies the build provenance attestation and aborts on mismatch.
- Installs under `~/.swift-claw` — no sudo. Re-running upgrades in place and never
  touches `clawd.env`, sealed secrets, or the database.
- Puts `~/.swift-claw/bin` on your `PATH` by writing `~/.swift-claw/env` and sourcing it
  from your shell rc files. Shells already open keep their old `PATH` — open a new one or
  run `. ~/.swift-claw/env` there. `CLAWD_NO_MODIFY_PATH=1` skips the shell-profile
  edits; `~/.swift-claw/env` is still written.
- Stages the launchd/systemd service unit without starting it — you configure first,
  then start it yourself (section 4).

Prefer not to pipe to sh? Download it first
(`curl -fsSLO https://raw.githubusercontent.com/ivan-magda/swift-claw/main/install.sh`),
read it, then run `sh install.sh` — or follow the manual install below.

> **Version skew:** pinned releases before v0.2.0 lack seal auto-scrub (blank the secret
> lines yourself after sealing), the doctor start hint, and the copy-pasteable
> `CLAW_ALLOWLIST=` line in the `/start` refusal (older releases print your numeric ID in
> prose — copy it by hand).

## 2. Manual install

From the [latest release](https://github.com/ivan-magda/swift-claw/releases/latest),
download the binary for your platform (`clawd-macos-arm64` or `clawd-linux-x86_64`),
`SHA256SUMS`, and `clawd.env.example`. Then verify and install from your download
directory:

```bash
cd ~/Downloads
ASSET=clawd-macos-arm64                             # Linux: clawd-linux-x86_64

shasum -a 256 --ignore-missing -c SHA256SUMS &&     # Linux: sha256sum --ignore-missing -c SHA256SUMS
  sudo install -m755 "$ASSET" /usr/local/bin/clawd
```

Every downloaded file must print `OK`; the `&&` stops the install if verification fails.
On a Mac without Homebrew, create the install directory first:
`sudo mkdir -p /usr/local/bin`.

- **macOS:** browser downloads carry the quarantine flag (curl downloads do not), so
  Gatekeeper blocks the unsigned binary until you clear it:
  `sudo xattr -d com.apple.quarantine /usr/local/bin/clawd`.
- **Linux:** the binary links the system SQLite (`sudo apt-get install -y libsqlite3-0`)
  and needs glibc 2.38 or newer (e.g. Ubuntu 24.04+); on older systems build from source.

Install the verified config template — your shell runs this file with `source`, so take
it from the checksummed release rather than an unverified copy:

```bash
mkdir -p -m 700 ~/.swift-claw
install -m 600 clawd.env.example ~/.swift-claw/clawd.env
```

Or build from source with a Swift 6.3 toolchain. On Linux, install the SQLite headers
first (`sudo apt-get install -y libsqlite3-dev`); the runtime package alone will not link:

```bash
git clone https://github.com/ivan-magda/swift-claw.git && cd swift-claw
swift build -c release
sudo install -m755 .build/release/clawd /usr/local/bin/clawd
```

From a source checkout the config template is `.env.example` in the repository root, and
the service files are under `deploy/`.

## 3. Verify downloads (optional)

`SHA256SUMS` lists the SHA-256 of every release asset; `--ignore-missing` checks only the
files present in your directory, and each one must print `OK`. The install script runs
this check for you — this section is for manual installs and extra assurance.

Every binary also carries a build provenance attestation. With the
[GitHub CLI](https://cli.github.com) installed and logged in (`gh auth login`):

```bash
gh attestation verify clawd-<platform> -R ivan-magda/swift-claw
gh attestation verify SHA256SUMS -R ivan-magda/swift-claw    # v0.2.0+
```

A verified `SHA256SUMS` covers every asset transitively: any file that matches a checksum
in an attested manifest came from the release workflow. Releases before v0.2.0 attest
only the binaries.

## 4. Running as a service

Both units are **per-user**: they start when you log in, not at boot, and stop when you
log out. Configure and seal first ([GETTING_STARTED.md](GETTING_STARTED.md)) — a healthy
`clawd doctor` ends by printing the exact start command for your machine.

### Script install (`~/.swift-claw` layout)

The install script already staged the unit, pointed at `~/.swift-claw/bin`. Start it:

```bash
# macOS
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.ivanmagda.swift-claw.plist

# Linux
systemctl --user enable --now swift-claw.service
```

### Manual install (`/usr/local/bin` layout)

Download `run-clawd.sh` plus your platform's unit (`com.ivanmagda.swift-claw.plist` or
`swift-claw.service`) from the same release and verify them against `SHA256SUMS` as in
section 3. You install `run-clawd.sh` as root and your machine runs it at every login,
which is reason enough not to take it from an unverified source.

macOS:

```bash
sudo install -m755 run-clawd.sh /usr/local/bin/run-clawd.sh
mkdir -p ~/Library/LaunchAgents && cp com.ivanmagda.swift-claw.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.ivanmagda.swift-claw.plist
```

Linux:

```bash
mkdir -p ~/.config/systemd/user && cp swift-claw.service ~/.config/systemd/user/
systemctl --user enable --now swift-claw.service
```

### Coder prerequisites

Coder is optional and off by default. Install a compatible native Codex CLI and Git separately;
GitHub sources and PRs also require the GitHub CLI (`gh`) and the account's repository rights.
The installer does not provision these tools, their dependencies, repository access or credentials.
The result schema is embedded in `clawd`; there is no extra schema resource to install.

Both service units run under your user account, but do not inherit an interactive shell's PATH or
login environment. The existing `run-clawd.sh` sources `~/.swift-claw/clawd.env` (or `CLAW_ENV_FILE`);
`clawd` itself does not load `.env` files. From a terminal where Codex and any interpreter it needs
work, run `clawd coder setup`. The command captures that terminal's absolute PATH entries for Coder
children, checks Codex locally, and writes only `CLAW_CODER_PATH` and `CLAW_CODER_ENABLED=true` to the
existing env file. `--dry-run` performs the checks without writing; `--env-file PATH` selects another
file. The daemon's global PATH is unchanged. Native preparation still uses `/usr/bin/git`.

Setup preserves an existing `CLAW_CODER_EXECUTABLE`, `CLAW_CODER_PROFILE` and
`CLAW_CODER_CONFIG_HOME`. It does not install tools, import authentication, edit shell startup files
or restart the service. Authenticate Codex and GitHub under the actual daemon account, with its HOME,
selected `CODEX_HOME`, profile and `GH_CONFIG_DIR`. Then restart the real launchd/systemd service and
send `/status` in the private bot chat. Check the effective directory count in `coder.path`, the
resolved `coder.executable`, `coder.node` when present, `coder.gh` for GitHub work, and authentication.
A successful setup probe in a terminal does not prove that the service can read the same auth source or
keyring. Rerun setup after an nvm or other tool-path change. `clawd auth` is independent.

`clawd doctor --check-config` stays offline and does not check Codex authentication. Full doctor uses
local CLI checks, not inference or credential refresh. Selected-profile authentication can remain
explicitly unverified; see
[CUSTOMIZATION.md](CUSTOMIZATION.md#coder-configuration). The supervised daemon auth/denial/cancellation
validation procedure is in [LOCAL_DEV.md](LOCAL_DEV.md#coder-background-lifecycle-and-recovery).

To stop new Coder tasks, set `CLAW_CODER_ENABLED=false` and restart. Disabled startup performs no
Codex probes and exposes no Coder tools, but still reconciles earlier jobs and reports retained
reservations in full doctor and daemon health. Follow the recovery procedure for unresolved ownership.

For Coder in an allowlisted Telegram group, make the bot a group administrator before enabling the
room. Group Coder approvals perform a fresh `getChatMember` lookup for every Approve or Deny tap, and
Telegram guarantees lookups for other users only when the bot is an administrator. A failed or
uncertain lookup leaves the approval pending. Keep group mode on its required separate nonpersonal
state root; see [LOCAL_DEV.md](LOCAL_DEV.md#group-mode-telegram-forum-supergroup).

The separate [conference challenge profile](CONFERENCE.md) requires a dedicated nonpersonal
host/account and state root. Set `CLAW_GROUP_CHATS` to the conference group ID and make the bot a
group administrator. Participants use mentions or replies in that group's topics; private messages
are ignored. Only a proposal's author can confirm it. Its supervisor publishes with a dedicated
GitHub bot-user token; that token is removed from Coder's child environment. Configure and authenticate the conference
Codex home within the state root, including after symlink resolution, before starting the service.

### Staying on after logout

- **Linux:** `sudo loginctl enable-linger $USER` lets the user manager run without a
  session. Without it, a service installed over SSH stops when you disconnect and does
  not come back after a reboot.
- **macOS:** enable automatic login for the account; that keeps the LaunchAgent, which is
  the simple path. A system LaunchDaemon in `/Library/LaunchDaemons` runs as root, where
  `$HOME` is `/var/root`, so the wrapper looks for its config in the wrong place and
  `clawd` exits 10 — if you go that route, pin the account and paths explicitly with
  `UserName`, `CLAW_ENV_FILE`, and `CLAW_STATE_ROOT` in the plist.

### Logs and exit codes

- **macOS:** `/tmp/clawd.out.log` and `/tmp/clawd.err.log`.
- **Linux:** `journalctl --user -u swift-claw -f`.

A second `clawd` against the same state root refuses to boot (file lock), and a Telegram
409 conflict is logged as critical. The commands that write into the state root take that
same lock — `clawd secrets seal`, `clawd auth login` / `logout`, and `clawd mcp set-token`
/ `clear-token` — so stop the service before running them. Read-only commands
(`clawd doctor`, `clawd auth status`, `clawd mcp list` / `probe`) are safe against a
running daemon. Exit codes are diagnostic:

| Code | Meaning                                    |
| ---- | ------------------------------------------ |
| 10   | invalid config                             |
| 11   | secret loading failed                      |
| 12   | another instance holds the state-root lock |
| 13   | storage error                              |

## 5. Updating

**Script layout:** re-run the one-liner from section 1. It upgrades the binary and
service unit in place, preserves `clawd.env`, sealed secrets, and the database, and
restarts the service if it was running.

**Manual layout:** re-download the binary and `SHA256SUMS` from the new release, re-verify
as in section 2, `sudo install` over the old binary, and restart the service
(`launchctl kickstart -k gui/$(id -u)/com.ivanmagda.swift-claw` on macOS,
`systemctl --user restart swift-claw.service` on Linux).

The two layouts do not mix: re-running the script on a manual install creates the
`~/.swift-claw/bin` layout alongside `/usr/local/bin/clawd`. The script notices the old
binary, prints that the new install supersedes it, and shows the removal command.

## 6. Uninstall

**Script layout** — remove the binary and service, keep config, secrets, and data:

```bash
curl -fsSL https://raw.githubusercontent.com/ivan-magda/swift-claw/main/install.sh | sh -s -- --uninstall
```

Also delete `~/.swift-claw` (config, secrets, database):

```bash
curl -fsSL https://raw.githubusercontent.com/ivan-magda/swift-claw/main/install.sh | sh -s -- --uninstall --purge
```

A plain `--uninstall` keeps `~/.swift-claw/env` because your shell rc files still source
it. After `--purge`, remove the `. "$HOME/.swift-claw/env"` line from your shell rc files
by hand, or shells will report a missing file at startup. The script never touches a
custom `CLAW_STATE_ROOT` outside `~/.swift-claw` — delete that directory yourself.

**Manual layout, macOS:**

```bash
launchctl bootout gui/$(id -u)/com.ivanmagda.swift-claw
rm ~/Library/LaunchAgents/com.ivanmagda.swift-claw.plist
sudo rm /usr/local/bin/clawd /usr/local/bin/run-clawd.sh
rm -rf ~/.swift-claw
```

**Manual layout, Linux:**

```bash
systemctl --user disable --now swift-claw.service
rm ~/.config/systemd/user/swift-claw.service
sudo rm /usr/local/bin/clawd
rm -rf ~/.swift-claw
systemctl --user daemon-reload
```
