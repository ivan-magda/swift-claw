# Local Apple renderer probe

This probe records the first research run. It proved MCP connectivity and image generation, but it
violates issue #179's renderer boundary because generated Swift runs through the local Apple
toolchain.

Do not wire this renderer into group mode.

## Files

- `Render.swift` renders one SwiftUI screen with `ImageRenderer` and AppKit.
- `HostingRender.swift` records the `NSHostingView` fallback probe.
- `iOSApp.swift` and `Info.plist` form the Simulator app bundle used by the live probe.
- `GeneratedPreview.swift` and `Harness.swift` record the split fixed-harness experiment.
- `mcp-server.py` exposes the temporary Streamable HTTP MCP handshake used by `swift-claw`.
- `mcp-client.py` calls the tool without involving the daemon.
- `mcp.example.yaml` records the tested `swift-claw` configuration shape.

## Historical reproduction

On a Mac with the Apple Swift toolchain:

```bash
swiftc Render.swift -o /tmp/swiftui-render
/tmp/swiftui-render /tmp/preview.png
```

The MCP handshake used Python's `mcp` package:

```bash
python3 mcp-server.py
python3 mcp-client.py
```

These commands document the experiment. They do not define a supported development workflow.
