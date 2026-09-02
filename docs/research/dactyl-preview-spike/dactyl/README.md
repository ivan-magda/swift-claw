# Dactyl remote renderer probe

This directory retains the account-independent pieces of the Dactyl experiment. The successful
live project remains in Dactyl. Its project ID and authentication state do not belong in Git.

## Files

- `ContentView.swift` and `DetailView.swift` preserve the two files from the successful persistent
  project build, with layout normalized by the repository formatter.
- `files-envelope.example.json` records the observed multi-file and asset request shape.
- `mount-preview.html` mounts a Dactyl Wasm URL through the browser SDK.
- `capture-preview.mjs` drives a Chromium debugging target and saves a screenshot.
- `mcp.example.yaml` shows the fixed-project sidecar configuration that current `swift-claw` can
  consume.

## Mounting an existing build

The HTML fixture needs a Wasm URL returned by a Dactyl build. It does not invoke the build API:

```bash
python3 -m http.server 8878 --directory .
open 'http://127.0.0.1:8878/mount-preview.html?wasm=https%3A%2F%2Fbuilder1.dactyl.dev%2F...wasm'
```

The SDK, symbol atlas, fonts, and glyphs still load from `builder1.dactyl.dev`. Cache or mirror them
before claiming an offline renderer.

## Capturing the canvas

Launch a disposable Chromium profile with a debugging port, then pass its page WebSocket URL to
the script:

```bash
node capture-preview.mjs \
  'ws://127.0.0.1:9222/devtools/page/PAGE_ID' \
  'http://127.0.0.1:8878/mount-preview.html?wasm=https%3A%2F%2Fbuilder1.dactyl.dev%2F...wasm' \
  '/tmp/dactyl-preview.png'
```

Do not reuse a profile that contains personal browsing data.

## Sidecar boundary

The proposed localhost MCP sidecar owns one Dactyl project ID and exposes:

```text
project_list_files
project_read_file
project_apply_files
preview_build
preview_snapshot
```

The account used in the spike did not expose Dactyl's beta coding-agent integration. Implement the
sidecar after Dactyl supplies the official MCP or local-sync contract.
