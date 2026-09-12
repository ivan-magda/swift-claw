# Dactyl-backed SwiftUI previews for Telegram topics

Research report, 2026-09-02. Repository at `main` (`0f317c29`). Related issue:
[#179](https://github.com/ivan-magda/swift-claw/issues/179).

This report records two spikes. The first proved the local renderer and Telegram delivery pieces,
but violated the product boundary. The second used Dactyl and established the path that fits the
requested product.

No production code or tests changed during either spike.

## Target experience

One Telegram forum topic represents one persistent application project. Participants ask the
agent to add screens, navigation, state, and assets. The agent updates the project, asks Dactyl to
build it to WebAssembly, captures the browser preview, and replies in the same topic.

Generated Swift must not run through local Xcode, Apple Simulator, or the host Swift runtime.

## Run 1: local Apple rendering

The first spike tested this pipeline:

```text
Telegram request
→ localhost MCP tool
→ generated SwiftUI
→ swiftc / Apple Simulator or AppKit renderer
→ PNG
→ public HTTPS URL
→ Telegram rich Markdown
```

### Verified

- `swift-claw` discovered and called a localhost Streamable HTTP MCP server.
- A fixed Swift harness could compile generated SwiftUI and render a PNG.
- A real iOS Simulator build produced screenshots.
- Telegram `sendRichMessage` rendered a public HTTPS PNG and retained the original topic and
  reply target.

### Decision

The renderer ran generated code through the local Apple toolchain. The harness also represented a
screen better than a persistent application project. This route remains useful as evidence
for MCP connectivity and Telegram image delivery, but it cannot serve as the product renderer.

The retained source lives in
[`dactyl-preview-spike/local`](dactyl-preview-spike/local/README.md).

## Run 2: Dactyl

The corrected spike used [Dactyl](https://dactyl.dev/) for remote SwiftUI compilation and browser
rendering.

### Persistent project

We created one project from a prompt in the Dactyl console. ZIP import was unnecessary. Dactyl
wrote and retained two files:

- `ContentView.swift`
- `DetailView.swift`

The initial AI turn stopped after writing the files because its provider refused the request. The
project still retained both files. Pressing **Reload simulator** compiled the saved project without
another AI turn.

The successful reload consumed one Dactyl credit. The account balance changed from 100 to 99.

### Runtime behavior

The browser preview showed the root counter list from `ContentView.swift`. A pointer tap opened
`DetailView.swift`. Another tap changed the bound counter from 28 to 29. This verifies:

- cross-file type resolution;
- `NavigationStack` navigation;
- `@State` and `@Binding` updates;
- interaction in the WebAssembly runtime;
- browser screenshot capture without an Apple runtime.

The retained source lives in
[`dactyl-preview-spike/dactyl`](dactyl-preview-spike/dactyl/README.md).

### Multi-file builder contract

The current Dactyl web client sends the builder a file map:

```http
POST https://builder1.dactyl.dev/build?project=<id>&base=<hash>&embedded=0&dynamic=0
Content-Type: application/json

{
  "files": {
    "ContentView.swift": "...",
    "DetailView.swift": "...",
    "Assets/dot.png": "data:image/png;base64,..."
  }
}
```

A request that used an array received an error asking for a
`{"files":{path:source,...}}` envelope. A deliberately broken symbol in `HelperView.swift`
produced a diagnostic attributed to that second file. Adding `Assets/dot.png` as a data URL passed
request validation and reached the same Swift diagnostic.

Two successful multi-file builds returned valid WebAssembly. One mounted result displayed text
defined in both `ContentView.swift` and `DetailView.swift`. The generated modules were about 80 MB
before transport compression.

Dactyl does not document this hosted endpoint as a stable integration contract. The public SDK
README tells integrators to host a build API. Treat the observed hosted endpoint as research
evidence, not a production dependency.

### Persistent project API

The shipped client uses these session-authenticated routes:

```text
GET/POST       /api/projects
GET/PUT/DELETE /api/projects/{id}
POST           /api/projects/{id}/fs
POST           /api/projects/{id}/revert
PATCH          /api/projects/{id}/meta
```

File updates use optimistic versions:

```json
{
  "baseVersion": 7,
  "ops": [
    {
      "op": "write",
      "path": "Screens/HomeView.swift",
      "content": "..."
    },
    {
      "op": "delete",
      "path": "OldView.swift"
    }
  ]
}
```

These routes require an authenticated session. We did not export browser cookies or put them in a
tool, prompt, file, or Git artifact.

### Coding-agent access

The current web client contains a **Connect coding agent** dialog with two integration modes:

- remote MCP for reading and editing files, running commands, building, and taking a live preview
  screenshot;
- local sync through Git, curl, a personal access token, and a Dactyl-provided skill.

The client shows this menu item only for `user.admin`. The tested account cannot create a token or
open the dialog. A support request asked Dactyl to enable the beta and provide its current tool and
API documentation.

Dactyl's MCP metadata advertises an authorization-code flow with PKCE S256 and refresh tokens. The
current `swift-claw` MCP client accepts a static token. Dactyl can remove the adapter requirement by
providing a PAT that its MCP endpoint accepts. An OAuth-only service needs a localhost sidecar that
owns token refresh.

### Screenshot behavior

Dactyl does not expose a documented headless screenshot endpoint. Its MCP integration asks the
open project tab for a snapshot over the project's agent WebSocket. The tab returns a JPEG data
URL captured from the Canvas runtime.

The experiment captured a PNG through browser automation. A production integration can keep the
same project tab open under a dedicated browser profile or use Dactyl's MCP snapshot once support
enables it.

## Smallest useful integration

Start with one supervised topic and one fixed project:

```text
Telegram topic
→ swift-claw tool loop
→ localhost Streamable HTTP MCP sidecar
→ fixed Dactyl project ID
→ read/apply files
→ Dactyl build
→ open project tab
→ snapshot
→ expiring HTTPS image URL
→ Telegram rich Markdown reply
```

The sidecar exposes five tools:

```text
project_list_files()
project_read_file(path)
project_apply_files(baseVersion, writes, deletes)
preview_build()
preview_snapshot()
```

The sidecar configuration owns the project ID. Model-authored arguments cannot select a project.

The first spike can use one dedicated `swift-claw` group installation and one chosen topic. The
operator records the project ID in the sidecar configuration and documents the binding in the
trusted `TOOLS.md`.

## Current swift-claw constraints

`SessionKey.telegramTopic` creates a stable key:

```text
tg:topic:<chatId>:<threadId|general>
```

`TurnRunner` passes the thread ID into `AgentRuntime`, but `ToolDispatchContext` contains only
security state and `ChatMode`. `Tool.execute` receives model arguments and a canonical target.
MCP sessions are composed once for the daemon and receive no session identity.

The fixed-project spike therefore relies on operator configuration. A multi-topic implementation
must pass the session key through the tool invocation path and resolve a stored topic-to-project
binding outside model arguments.

The MCP adapter reduces image content to `[image: MIME]`. It does not pass image bytes to the model
or Telegram. `preview_snapshot` should publish the image at an expiring HTTPS URL and return that
URL in text content. A trusted `TOOLS.md` rule can format it as:

```markdown
![](https://preview.example/random-id.png "iOS preview")
```

The first run verified that the current Telegram rich-message path renders this form and keeps the
topic target. The URL should use an unguessable path and expire after the outbox retry window.

## Security boundary

- Run the spike from the supervised group installation and its separate state root.
- Store the Dactyl token in the host secret store or OAuth sidecar.
- Keep browser cookies inside the dedicated browser profile.
- Restrict the sidecar to one project and the five tools above.
- Exclude publishing, project deletion, arbitrary commands, and Apple credentials.
- Upload files only from the topic-bound workspace.
- Set build, repair-loop, project-size, and artifact-retention caps.
- Label output as a Dactyl compatibility preview. Xcode and a real device remain authoritative.

## Open work

1. Receive Dactyl beta access, a PAT, or OAuth tool schemas.
2. Verify the official edit, build, and snapshot loop against the retained project.
3. Connect a fixed-project sidecar to one supervised Telegram topic.
4. Add session identity to tool dispatch before supporting more than one topic.
5. Add a durable outbound artifact model if temporary HTTPS media proves insufficient.

## Sources

- [How Dactyl works](https://dactyl.dev/blog/how-dactyl-works/)
- [Dactyl workspace](https://dactyl.dev/docs/workspace/)
- [Dactyl preview and testing](https://dactyl.dev/docs/preview/)
- [Dactyl troubleshooting](https://dactyl.dev/docs/troubleshooting/)
- [Dactyl pricing](https://dactyl.dev/pricing/)
- [Dactyl SDK README](https://builder1.dactyl.dev/src/sdk/README.md)
