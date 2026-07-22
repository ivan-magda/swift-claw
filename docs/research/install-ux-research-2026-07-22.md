# Install-UX research: how the best CLI tools ship, and what swift-claw should borrow

*2026-07-22. Five parallel research lanes (installer scripts, docs structure, `curl | sh`
security, onboarding wizards, OpenClaw/Hermes prior art), each grounded in fetched primary
sources: the actual install scripts and docs rather than summaries. A verify pass checked
28 load-bearing claims against those sources: 23 confirmed, 5 corrected (listed at the
end). The central macOS claim also held on a real machine: a curl-downloaded release
binary carries no `com.apple.quarantine` attribute.*

## 1. Recommendation

Ship a single repo-committed `install.sh` behind a curl one-liner as the front door (the
Ollama/Tailscale/uv script-first model), and make it the only thing the README install
section shows besides a "view script source" link and a manual-install link. The script is
dependency-free (curl + shasum only) and **sudo-free**: everything lands under
`~/.swift-claw/` (the Hermes layout), which makes the whole footprint one directory and
pairs with the existing per-user launchd/systemd units. It verifies the release
`SHA256SUMS` inside the script, **drops the `xattr` step on the curl path**
(curl-fetched files carry no `com.apple.quarantine` flag, so the unsigned binary runs
unprompted), stages the env template and pre-templated service units, and ends by printing
a short numbered next-step block that converges on `clawd doctor`. Everything interactive
(BotFather token, sealing, owner allowlist, service start) stays out of the script: it
lives in the docs now, and in a `clawd onboard` wizard plus `clawd service install`
subcommand later, because a piped script has no safe way to prompt and both studied daemon
installers (Tailscale, Ollama) ask zero questions and defer interaction to the binary.
Re-running the script is the upgrade path: idempotent, restarts a running service, and
leaves an existing `clawd.env` untouched.

## 2. `install.sh`: researched behavior

One-liners (script served from `raw.githubusercontent.com` on `main`; also uploaded as a
checksummed release asset so the download-inspect-run path can verify the script itself):

```bash
curl -fsSL https://raw.githubusercontent.com/ivan-magda/swift-claw/main/install.sh | sh
curl -fsSL .../install.sh | CLAWD_VERSION=v0.2.0 sh     # pinned release
```

Step by step, each grounded in an exemplar:

1. **Skeleton.** `#!/bin/sh`, `set -eu`, all logic in functions, `main "$@"` on the last
   line, the truncated-download guard rustup/ollama/tailscale/uv all use. `trap cleanup
   EXIT` around a `mktemp -d` workdir. No prompts at all (Tailscale/Ollama pattern;
   sidesteps the `/dev/tty` machinery).
2. **Platform detect.** `uname -s`/`uname -m` → the two release assets. On Darwin, check
   Rosetta via `sysctl -n sysctl.proc_translated` (bun's trick) so Intel Macs get a clear
   "unsupported, build from source" message. Gate macOS ≥ 15 via `sw_vers` (Homebrew's
   OS-bound check). Unsupported triple → actionable failure output (Tailscale's UX).
3. **Preflight.** Require curl (with `--proto '=https' --tlsv1.2` on every fetch, rustup's
   transport hardening) and a SHA-256 tool. On Linux, probe `libsqlite3.so.0` and hard-fail
   with the exact `apt-get` line if missing.
4. **Verify inside the script.** Check every downloaded asset against the release
   `SHA256SUMS`; abort with a clear error on mismatch. Stronger than Ollama (no
   verification) and stricter than uv/cargo-dist (which skip verification without a
   message when the hash tool is absent; we made the hash tool a hard preflight
   requirement). When `gh` is present and authenticated, also run
   `gh attestation verify`; otherwise print it as an optional manual step. The script
   does not require attestation: the bootstrap problem (you cannot verify your first
   install with a tool you have not installed) is why no studied installer requires it.
5. **No quarantine handling.** curl does not set `com.apple.quarantine` (only apps opting
   into `LSFileQuarantineEnabled` tag their downloads), and Gatekeeper (including the
   Catalina+ CLI-exec check and the Sequoia tightening) assesses only files that carry the
   flag. The `xattr -d` step belongs only in the manual/browser-download docs.
6. **Install, no sudo.** Binary to `~/.swift-claw/bin/clawd` via a two-phase move (uv's
   atomicity pattern); env template copied to `clawd.env` only if absent, so the script
   does not overwrite user config. The industry converged on `$HOME` installs for user tools
   (rustup/bun/deno/uv/atuin), and clawd's services are already per-user.
7. **PATH.** An env script at `~/.swift-claw/env` (the rustup/uv
   `case ":$PATH:"` pattern: idempotent, uninstall-friendly, late-bound `$HOME`) plus
   grep-guarded rc-file lines; opt-out via `CLAWD_NO_MODIFY_PATH=1`.
8. **Service staging, config-gated start.** Write the unit files retargeted to the real
   install paths, but do not start an unconfigured daemon (clawd exits 10/11); no studied
   tool ships a deliberate crash-loop. Interaction converges on `clawd doctor`, which ends
   a healthy run by printing the platform's service-start command (the flutter/brew doctor
   contract: one check per line, fix-forward guidance, no dead ends).
9. **Idempotent re-run = upgrade** (universal across studied scripts; Ollama
   stops/cleans/restarts). The re-run leaves config, secrets, and the SQLite store
   untouched.
10. **End print** (Tailscale/atuin shape): state what is now true, one command per line,
    one link to the full guide.

The script leaves out: all secrets input and sealing (clig.dev: no secrets via
flags/env; a piped script has no safe TTY story), Telegram token validation, the allowlist
round-trip, `clawd auth login` sequencing (must not run while the daemon holds the state
lock), and first-install service start.

## 3. First-run configuration findings

- The flow the docs walk: BotFather → edit `clawd.env` → seal → doctor → foreground run +
  `/start` → allowlist → service start. Each step ends by telling you the next (fzf's
  "no dead ends" rule).
- **Seal should scrub its own plaintext.** "Delete lines by hand from a file you got
  working moments ago" is the single most error-prone step in the current flow, and it is
  mechanical, the kind of work the binary should own.
- **The refusal message should be copy-pasteable.** OpenClaw's pairing still asks for
  numeric IDs in setup; the win in pairing is that the first DM carries the ID, which
  clawd's `/start` refusal already exploits. It needs to print the exact
  `CLAW_ALLOWLIST=<id>` line on top (clig.dev: suggest the next command).
- **Doctor is the convergence command** (Tailscale's `tailscale up`, flutter/brew doctor):
  non-zero exit iff a blocker remains, and a passing run should print the service-start
  command so the docs need not fork by platform mid-page.
- Phase 2 (deferred): `clawd service install|start|status|uninstall` and a `clawd onboard`
  wizard. Both OpenClaw (`openclaw onboard`, daemon install as a wizard step) and Hermes
  (`hermes gateway install`) ship this pair, and OpenClaw issue #48471 documents the
  demand ("users consistently arrive expecting `curl install.sh | bash` to be enough").
  Wizard essentials from the research: validate the token at entry with a live `getMe`
  echoing "Connected as @yourbot", persist only verified provider routes, non-interactive
  twins for every prompt, re-runnable without `--reset`, and end only after the daemon is
  confirmed running.

## 4. Docs structure findings

- **One lifecycle page** (Ollama's Linux docs): install → manual install → service (full
  unit inline) → updating → logs → uninstall, in that order, on one page → our new
  `docs/INSTALL.md`. `deploy/README.md` shrinks to a pointer.
- **README install section** = one-liner + pin variant + "view script source" + manual
  link, ≤ 10 lines (uv/atuin shape). The Ollama download page is one command plus
  two links.
- **Uninstall is a first-class heading at the bottom**, per clig.dev verbatim: "Make it easy
  to uninstall. If it needs instructions, put them at the bottom of the install
  instructions."
- **Verification is optional and framed as such** (restic's "if you desire" wording), and
  it stays out of the quick path.
- **"Prefer not to `curl | sh`?"** gets one sentence routing to the manual path (Tailscale:
  "If you prefer not to use `curl | sh`, visit ... for manual installation instructions").

## 5. Security posture findings

- Real vs theater in the `curl | bash` debate: partial-execution is real but cheap to
  mitigate (`main` on the last line); server-side pipe-detection is a demonstrated but
  finicky PoC, and defending against it is theater against an operator you already trust
  (Sandstorm's argument: HTTPS is the same trust base npm et al. rely on).
- In-script checksums defend against corruption and partial downloads, not a compromised
  host: checksums and binaries come from the same origin. The docs say so outright.
- GitHub build-provenance attestations carry the trust weight
  (`gh attestation verify`, Sigstore-backed, validates the producing workflow). Verify
  in-script when `gh` is available; document the manual command otherwise. The release
  should attest the checksum manifest itself, not only the binaries, so the attestation
  covers the units/env-template the installer executes transitively.
- Rejected: GPG signing (restic-grade machinery, solo-maintainer cost), notarization
  ($99/yr to spare the browser-download minority one documented `xattr` line), server-side
  UA sniffing defenses, required attestation (bootstrap problem).

## 6. Maintenance cost findings

One-time: the script (~250 lines, dependency-free; OpenClaw's #1 install-failure class is
its runtime deps, and a static binary must not squander that advantage), the docs
restructure, a shellcheck CI job, small release.yml additions. Recurring: near zero.
The script is version-agnostic (`releases/latest` + env-var pin), so releases leave it
untouched. No new hosting: raw.githubusercontent + GitHub Releases.

## 7. Out of scope / rejected alternatives

Homebrew tap now (per-release bumps on a solo maintainer; the "unsigned binaries belong in
a tap" line is community practice, not documented Homebrew policy, so revisit later);
apt/rpm repos (Tailscale-scale infrastructure); cargo-dist/GoReleaser (not SwiftPM-native:
borrow the patterns, not the tools); interactive prompts inside install.sh; the full
OpenClaw/Hermes pairing-code subsystem (a feature, not an install fix); `clawd onboard`
now (the wizard should automate a documented, proven flow rather than an invented one).

## Fact-check corrections (claims the verify pass refuted or narrowed)

1. "Piped installers prompt via `/dev/tty` with a clean no-tty error" is overstated: only
   rustup and starship fail with a clear error; atuin and Homebrew fall back to
   non-interactive without a message; deno skips prompts.
2. "User-level installers all grep-guard rc appends and wrap in `main()`" is wrong on both
   counts: bun's appends are unguarded and bun/deno have no `main()` wrapper; the guard
   pattern is atuin's, the wrapper is rustup/uv/ollama/tailscale's.
3. "Tailscale routes users 'hesitant about piping to shell'": the actual wording is "If
   you prefer not to use `curl | sh`"; substance holds.
4. "macOS Sequoia 15.1 moved unsigned-app approval to System Settings; GUI-only scoping":
   the cited source attributes both changes to Sequoia 15 and says nothing about
   GUI-vs-CLI scoping; the CLI claim rests on the quarantine-flag mechanics (confirmed by
   the real-machine test), not on the Sequoia article.
5. "OpenClaw onboards via `openclaw onboard --install-daemon` and identifies the owner via
   pairing rather than numeric IDs": the flag does not exist (daemon install is a built-in
   wizard step), token validation happens at gateway startup rather than paste time, and
   setup still asks for numeric user IDs.

## Amendments made during plan review (deviations from §2 above)

- The documented pin form `CLAWD_VERSION=vX curl ... | sh` is wrong: the variable scopes
  to curl, not to sh. The correct piped form is `curl ... | CLAWD_VERSION=vX sh`.
- The review dropped Linux service auto-enable via `ConditionPathExists`: unmet systemd
  conditions make `systemctl start` a no-op with no message, which turns doctor's printed
  start command into a mystery for anyone the condition does not cover. Both platforms now
  stage units without enabling; doctor prints the start command when healthy.
- The Linux release binary requires glibc ≥ 2.38 (CI builds it in the `swift:6.3-noble`
  container; symbol inspection of the v0.1.1 asset confirmed it). The installer
  preflights this and the docs state the floor.
- A loaded launchd agent runs launchd's cached definition; replacing the plist requires
  `bootout` + `bootstrap`, not `kickstart`.
