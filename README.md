# swift-claw

A persistent, single-owner personal AI assistant controlled via Telegram, written in pure Swift. The daemon is `clawd`.

> Design docs live in [`docs/`](docs/) — `ARCHITECTURE.md` is the normative spec.

## Install a release binary

Download the binary for your platform from the [latest release](../../releases/latest), then verify it:

```bash
sha256sum -c SHA256SUMS                      # Linux
shasum -a 256 -c SHA256SUMS                   # macOS
gh attestation verify clawd-linux-x86_64 -R ivan-magda/swift-claw
```

- **macOS:** first run is blocked by Gatekeeper for an unsigned binary — clear the quarantine flag: `xattr -d com.apple.quarantine ./clawd-macos-arm64`.
- **Linux:** the binary links the system SQLite — install it if missing: `sudo apt-get install -y libsqlite3-0`.

## Build from source

Requires the Swift 6.3.x toolchain.

```bash
swift build            # debug → .build/debug/clawd
swift build -c release # release → .build/release/clawd
swift test             # run the suite
```

See [`docs/LOCAL_DEV.md`](docs/LOCAL_DEV.md) for running the daemon and [`deploy/README.md`](deploy/README.md) for supervised deployment.
