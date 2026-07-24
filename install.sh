#!/bin/sh
# swift-claw installer.
#
#   curl -fsSL https://raw.githubusercontent.com/ivan-magda/swift-claw/main/install.sh | sh
#
# Everything is installed under ~/.swift-claw — no sudo. Re-running upgrades in
# place and never touches clawd.env, sealed secrets, or the database.
#
#   ... | CLAWD_VERSION=v0.2.0 sh       pin a release (default: latest)
#   ... | CLAWD_NO_MODIFY_PATH=1 sh     skip shell-profile PATH edits
#   ... | sh -s -- --uninstall          remove binary + service, keep config/data
#   ... | sh -s -- --uninstall --purge  also delete ~/.swift-claw
#
# main() on the last line: a truncated download can never execute a partial script.
set -eu

REPO="ivan-magda/swift-claw"
SERVICE_LABEL="com.ivanmagda.swift-claw"
CLAW_HOME="${HOME}/.swift-claw"
BIN_DIR="${CLAW_HOME}/bin"
# The Linux binary is built in the swift:6.3-noble container and links its glibc.
# Bump in lockstep with the builder image in .github/workflows/release.yml.
GLIBC_FLOOR="2.38"

say() { printf '%s\n' "$*"; }
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

fetch() {
  # $1 url, $2 dest. TLS floor pinned; --retry rides out transient CDN failures.
  curl --proto '=https' --tlsv1.2 -fsSL --retry 3 -o "$2" "$1" \
    || die "download failed: $1"
}

sha256_check() {
  # A function, not a command string: zsh would not word-split "shasum -a 256".
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 --ignore-missing -c SHA256SUMS >/dev/null
  else
    sha256sum --ignore-missing -c SHA256SUMS >/dev/null
  fi
}

detect_platform() {
  host_os="$(uname -s)"
  host_arch="$(uname -m)"
  case "$host_os" in
    Darwin)
      if [ "$host_arch" != "arm64" ] \
        || [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = "1" ]; then
        die "no release binary for Intel Macs (or Rosetta shells) — build from source:
  https://github.com/${REPO}#install"
      fi
      macos_major="$(sw_vers -productVersion | cut -d. -f1)"
      [ "$macos_major" -ge 15 ] \
        || die "macOS 15 or newer required (found $(sw_vers -productVersion))"
      ASSET="clawd-macos-arm64"
      UNIT_ASSET="${SERVICE_LABEL}.plist"
      ;;
    Linux)
      [ "$host_arch" = "x86_64" ] || die "no release binary for Linux/$host_arch — build from source:
  https://github.com/${REPO}#install"
      glibc_version="$(ldd --version 2>/dev/null | sed -n '1s/.* //p')"
      if [ -n "$glibc_version" ] && [ "$(printf '%s\n' "$GLIBC_FLOOR" "$glibc_version" \
        | sort -V | head -n1)" != "$GLIBC_FLOOR" ]; then
        die "glibc $glibc_version is too old (the release binary needs >= $GLIBC_FLOOR,
  e.g. Ubuntu 24.04+). Build from source instead: https://github.com/${REPO}#install"
      fi
      ASSET="clawd-linux-x86_64"
      UNIT_ASSET="swift-claw.service"
      ;;
    *)
      die "unsupported OS: $host_os (macOS arm64 and Linux x86_64 have release binaries)"
      ;;
  esac
}

preflight() {
  command -v curl >/dev/null 2>&1 || die "curl is required"
  command -v shasum >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1 \
    || die "shasum or sha256sum is required"
  if [ "$(uname -s)" = "Linux" ] && command -v ldconfig >/dev/null 2>&1 \
    && ! ldconfig -p | grep -q 'libsqlite3\.so\.0'; then
    die "libsqlite3 is missing. Install it first:
  sudo apt-get install -y libsqlite3-0    # Debian/Ubuntu"
  fi
}

release_url() {
  # $1 asset name
  if [ -n "${CLAWD_VERSION:-}" ]; then
    printf 'https://github.com/%s/releases/download/%s/%s' "$REPO" "$CLAWD_VERSION" "$1"
  else
    printf 'https://github.com/%s/releases/latest/download/%s' "$REPO" "$1"
  fi
}

download_and_verify() {
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' EXIT
  say "Downloading ${CLAWD_VERSION:-latest} release assets..."
  for asset_name in "$ASSET" SHA256SUMS clawd.env.example run-clawd.sh "$UNIT_ASSET"; do
    fetch "$(release_url "$asset_name")" "$workdir/$asset_name"
  done
  say "Verifying checksums..."
  (cd "$workdir" && sha256_check) \
    || die "checksum verification FAILED — aborting; nothing was installed"
  ATTESTED="attestation not checked (optional; install+login the GitHub CLI and run:
    gh attestation verify \"$BIN_DIR/clawd\" -R $REPO)"
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    # An unpinned install still resolves to one concrete tag: the first redirect of
    # the latest-release URL carries it, so the >= v0.2.0 fail-closed rule below can
    # apply to "latest" exactly as it does to a pin. Empty on failure = unresolvable.
    effective_tag="${CLAWD_VERSION:-}"
    if [ -z "$effective_tag" ]; then
      effective_tag="$(curl --proto '=https' --tlsv1.2 -fsSI -o /dev/null \
        -w '%{redirect_url}' \
        "https://github.com/${REPO}/releases/latest/download/SHA256SUMS" 2>/dev/null \
        | sed -n 's|.*/download/\(v[^/]*\)/.*|\1|p')" || effective_tag=""
    fi
    # The manifest attestation covers every asset transitively; releases before
    # v0.2.0 attest only the binaries.
    gh attestation verify "$workdir/$ASSET" -R "$REPO" >/dev/null 2>&1 \
      || die "GitHub attestation verification FAILED for $ASSET — aborting"
    if gh attestation verify "$workdir/SHA256SUMS" -R "$REPO" >/dev/null 2>&1; then
      ATTESTED="binary + manifest attestation OK"
    elif [ -n "$effective_tag" ] && [ "$(printf '%s\n' "v0.2.0" "$effective_tag" \
      | sort -V | head -n1)" = "v0.2.0" ]; then
      # Every release from v0.2.0 attests its manifest, so a modern release with an
      # unverifiable SHA256SUMS is not trustworthy.
      die "manifest attestation verification FAILED for SHA256SUMS ($effective_tag) — aborting"
    else
      ATTESTED="binary attestation OK, manifest unattested — if the installed release is
    v0.2.0 or newer, do NOT trust it; verify manually:
    gh attestation verify SHA256SUMS -R $REPO"
    fi
  fi
}

install_files() {
  umask 077
  mkdir -p "$BIN_DIR"
  chmod 700 "$CLAW_HOME"
  # Two-phase move: smoke-test the candidate first, so a binary that cannot run
  # here never replaces a working install and no half-written file lands at the
  # final path.
  install -m 755 "$workdir/$ASSET" "$BIN_DIR/.clawd.new"
  if ! INSTALLED_VERSION="$("$BIN_DIR/.clawd.new" --version 2>/dev/null)"; then
    rm -f "$BIN_DIR/.clawd.new"
    die "the installed binary failed to run on this machine.
  On Linux this usually means glibc is older than $GLIBC_FLOOR. Build from source:
  https://github.com/${REPO}#install"
  fi
  mv -f "$BIN_DIR/.clawd.new" "$BIN_DIR/clawd"
  # run-clawd.sh defaults to /usr/local/bin/clawd; point the default here instead.
  sed 's|/usr/local/bin/clawd|'"$BIN_DIR"'/clawd|' "$workdir/run-clawd.sh" \
    > "$BIN_DIR/run-clawd.sh"
  chmod 755 "$BIN_DIR/run-clawd.sh"
  install -m 600 "$workdir/clawd.env.example" "$CLAW_HOME/clawd.env.example"
  if [ ! -f "$CLAW_HOME/clawd.env" ]; then
    install -m 600 "$workdir/clawd.env.example" "$CLAW_HOME/clawd.env"
    ENV_CREATED=1
  else
    ENV_CREATED=0
  fi
}

setup_path() {
  cat > "$CLAW_HOME/env" <<'EOF'
#!/bin/sh
# Adds ~/.swift-claw/bin to PATH. Written by install.sh; safe to source repeatedly.
case ":${PATH}:" in
  *:"$HOME/.swift-claw/bin":*) ;;
  *) export PATH="$HOME/.swift-claw/bin:$PATH" ;;
esac
EOF
  # The opt-out skips only the rc-file edits; the env helper above always exists.
  [ "${CLAWD_NO_MODIFY_PATH:-0}" = "1" ] && return 0
  sourced_somewhere=0
  for rcfile in "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.bashrc" "$HOME/.bash_profile" \
    "$HOME/.profile"; do
    [ -f "$rcfile" ] || continue
    # shellcheck disable=SC2016  # literal $HOME: the rc line must expand at shell startup
    grep -qs '\.swift-claw/env' "$rcfile" \
      || printf '\n. "$HOME/.swift-claw/env"\n' >> "$rcfile"
    sourced_somewhere=1
  done
  if [ "$sourced_somewhere" = "0" ]; then
    # A fresh account may have no rc files at all; create the platform's login default.
    case "$(uname -s)" in
      Darwin) default_rc="$HOME/.zprofile" ;;
      *) default_rc="$HOME/.profile" ;;
    esac
    # shellcheck disable=SC2016  # literal $HOME, as above
    printf '\n. "$HOME/.swift-claw/env"\n' >> "$default_rc"
  fi
}

stage_service() {
  case "$(uname -s)" in
    Darwin)
      UNIT_DEST="$HOME/Library/LaunchAgents/${SERVICE_LABEL}.plist"
      mkdir -p "$HOME/Library/LaunchAgents"
      was_loaded=0
      launchctl print "gui/$(id -u)/${SERVICE_LABEL}" >/dev/null 2>&1 && was_loaded=1
      # The shipped plist points at /usr/local/bin; retarget it to this install.
      sed 's|/usr/local/bin/run-clawd.sh|'"$BIN_DIR"'/run-clawd.sh|' \
        "$workdir/$UNIT_ASSET" > "$UNIT_DEST"
      START_CMD="launchctl bootstrap gui/$(id -u) $UNIT_DEST"
      if [ "$was_loaded" = "1" ]; then
        # A loaded agent runs launchd's cached definition; only bootout+bootstrap
        # picks up the rewritten plist. bootout returns before the job finishes
        # draining, so wait for the label to disappear before re-bootstrapping.
        launchctl bootout "gui/$(id -u)/${SERVICE_LABEL}" 2>/dev/null || true
        drain_wait=0
        while launchctl print "gui/$(id -u)/${SERVICE_LABEL}" >/dev/null 2>&1; do
          drain_wait=$((drain_wait + 1))
          [ "$drain_wait" -ge 20 ] && break
          sleep 1
        done
        if launchctl bootstrap "gui/$(id -u)" "$UNIT_DEST"; then
          SERVICE_STATE="reloaded and restarted"
        else
          SERVICE_STATE="updated on disk; reload failed — start it manually: $START_CMD"
        fi
      else
        SERVICE_STATE="staged (not started — configure first)"
      fi
      ;;
    Linux)
      UNIT_DEST="$HOME/.config/systemd/user/swift-claw.service"
      mkdir -p "$HOME/.config/systemd/user"
      # %h is systemd's home specifier, valid in ExecStart.
      sed 's|/usr/local/bin/clawd|%h/.swift-claw/bin/clawd|' \
        "$workdir/$UNIT_ASSET" > "$UNIT_DEST"
      # A systemctl binary alone proves nothing (WSL ships one without a running
      # systemd); a live user manager leaves this directory, the same probe doctor uses.
      if [ -d /run/systemd/system ]; then
        START_CMD="systemctl --user enable --now swift-claw.service"
        systemctl --user daemon-reload 2>/dev/null || true
        if systemctl --user is-active --quiet swift-claw.service 2>/dev/null; then
          systemctl --user restart swift-claw.service
          SERVICE_STATE="restarted"
        else
          SERVICE_STATE="staged (not started — configure first)"
        fi
      else
        START_CMD="clawd run"
        SERVICE_STATE="staged (no systemd detected; run the daemon with: clawd run)"
      fi
      ;;
  esac
}

print_next_steps() {
  say ""
  say "clawd $INSTALLED_VERSION installed to $BIN_DIR (checksum OK, $ATTESTED)"
  say "Service unit: $UNIT_DEST — $SERVICE_STATE"
  if [ -x /usr/local/bin/clawd ]; then
    say "Note: an older /usr/local/bin/clawd exists; this install supersedes it."
    say "      Remove it with: sudo rm /usr/local/bin/clawd /usr/local/bin/run-clawd.sh"
  fi
  # The invoking shell inherited its PATH before setup_path edited the rc files, so
  # `clawd` stays unfound in that shell even after a successful (re-)install.
  case ":${PATH}:" in
    *:"$BIN_DIR":*) ;;
    *)
      say "This shell's PATH does not include $BIN_DIR yet —"
      say "open a new shell, or run: . \"\$HOME/.swift-claw/env\""
      ;;
  esac
  if [ "$ENV_CREATED" = "1" ]; then
    say ""
    say "Next steps:"
    say "  1. Get a bot token from @BotFather (https://t.me/BotFather, send /newbot)"
    say "  2. Edit ~/.swift-claw/clawd.env — set the token and your LLM provider"
    say "  3. Load it and seal the secrets:"
    say "       set -a && . ~/.swift-claw/clawd.env && set +a && clawd secrets seal"
    say "  4. Say hello once in the foreground: clawd run"
    say "     (send /start to your bot — the refusal shows your numeric ID; set it as"
    say "      CLAW_ALLOWLIST=<id> in clawd.env, then Ctrl-C)"
    say "  5. Check health and start the service:"
    say "       set -a && . ~/.swift-claw/clawd.env && set +a && clawd doctor && $START_CMD"
    say ""
    say "Full guide: https://github.com/${REPO}/blob/main/docs/GETTING_STARTED.md"
  else
    say "Existing config kept: $CLAW_HOME/clawd.env"
  fi
}

uninstall() {
  purge_data="$1"
  case "$(uname -s)" in
    Darwin)
      launchctl bootout "gui/$(id -u)/${SERVICE_LABEL}" 2>/dev/null || true
      rm -f "$HOME/Library/LaunchAgents/${SERVICE_LABEL}.plist"
      ;;
    Linux)
      systemctl --user disable --now swift-claw.service 2>/dev/null || true
      rm -f "$HOME/.config/systemd/user/swift-claw.service"
      systemctl --user daemon-reload 2>/dev/null || true
      ;;
  esac
  # $CLAW_HOME/env stays on plain uninstall: rc lines still source it, and a missing
  # file would error on every shell startup (rustup keeps its env file for the same reason).
  rm -rf "$BIN_DIR" "$CLAW_HOME/clawd.env.example"
  if [ "$purge_data" = "1" ]; then
    rm -rf "$CLAW_HOME"
    say "Removed $CLAW_HOME."
    if [ -n "${CLAW_STATE_ROOT:-}" ] && [ "$CLAW_STATE_ROOT" != "$CLAW_HOME" ]; then
      say "Note: your custom CLAW_STATE_ROOT at $CLAW_STATE_ROOT was NOT touched."
    fi
    say "Your shell profile may still source \$HOME/.swift-claw/env — remove that line"
    say "by hand, or shells will report a missing file at startup."
  else
    say "Removed the binary and service. Config, secrets, and data remain in $CLAW_HOME"
    say "(delete them with: rm -rf $CLAW_HOME)"
  fi
}

main() {
  if [ "${1:-}" = "--uninstall" ]; then
    purge_flag=0
    [ "${2:-}" = "--purge" ] && purge_flag=1
    uninstall "$purge_flag"
    exit 0
  fi
  [ -z "${1:-}" ] || die "unknown argument: $1 (supported: --uninstall [--purge])"
  detect_platform
  preflight
  download_and_verify
  install_files
  setup_path
  stage_service
  print_next_steps
}

main "$@"
