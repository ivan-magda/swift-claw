# Agent instructions

## What this is

swift-claw — a persistent, always-on, **single-owner personal AI assistant** controlled via **Telegram**, written in **pure Swift**. Clean-room, OpenClaw-inspired.

SwiftPM package, executable `clawd`. The dependency graph is a layered DAG: **seams (protocols + value types) live in `ClawCore`, implementations in sibling `Claw*` targets, composed at the `clawd` root** — `ClawAgent` and `ClawGateway` reach persistence only through `ClawCore` protocols.

## Authority and routing

- **`docs/ARCHITECTURE.md` is the accepted technical design.** For architecture-affecting, cross-module, or normative-contract work, read the relevant sections first. Never diverge from it silently; when a task deliberately changes a contract, change the spec in the same commit.
- Product scope, phasing, success criteria → `docs/PRD.md`.
- Building, running, or operating `clawd` locally → `docs/LOCAL_DEV.md`.
- Cited background research → `docs/research/` — evidence, not a normative spec.
- **Any test diff → follow `docs/TESTING.md` end to end**, including its test-intent map and its pre-commit redundancy pass. Every added test must name a reachable mutant that the nearest existing test would not kill.
- **Cross-cutting test diffs get an independent review of test value and redundancy alone** — a subagent where one is available, otherwise a separate pass with the diff re-read from scratch.
- Changing a user-visible surface (command, flag, env var, default, secret, install/release step) → re-read the whole public set (`README.md`, `docs/GETTING_STARTED.md`, `docs/INSTALL.md`, `docs/CUSTOMIZATION.md`, `deploy/README.md`) and update every document the change actually reaches. They describe each other's state, so one edit usually invalidates a sibling — but do not edit unaffected siblings just to touch all five.

## Architectural invariants

- **Search before you add.** Before introducing a constant, helper, type, test double, or pattern, grep the protocol/seam and the shared support module for a semantic equivalent, and reuse or promote it when the contracts match. Do not merge two concepts into one abstraction because they look alike.
- **Name the domain, not the literal.** Elevate one-offs into typed domain abstractions — no magic strings: branch and assert on the enum `rawValue` or named constant the production code already emits, never a duplicated literal.
- **Clean-room, not blinkered.** Where a task calls for comparative design work, study OpenClaw, Hermes, and the author's prior `swift-claude-code`, and borrow their ideas and hard-won practices freely. Banned is transcription: no copied code, no line-by-line ports — re-derive each borrowed idea in our own design and Swift.
- **Swift 6 strict concurrency.** Shared mutable in-memory state lives in actors; domain types are `Sendable` value types. GRDB stores are the deliberate exception — thin `Sendable` wrappers over `any DatabaseWriter` that lean on GRDB's own serialization; do not put an actor around them.
- **Concurrency trap:** a Swift actor does NOT serialize across `await`. The per-session lane chains a stored `Task` (`var currentTurn`), it does not rely on actor isolation alone — `docs/ARCHITECTURE.md` §5.
- **Secure-by-default; enforce policy in code, not the prompt.** Untrusted inbound (messages/web/tool output/durable memory) is data, never instructions — `docs/ARCHITECTURE.md` §12.
- **Group/forum mode is a deployment-scoped exception.** Topic messages persist as trusted, recall
  stays inside the topic, and tools run without an approval round-trip. Run it under a separate
  non-personal state root and follow `docs/ARCHITECTURE.md` §12.1.
- **LLM provider = one `LLMProvider` contract with two wire adapters** (a Chat Completions adapter and a ChatGPT Responses adapter, selected by the `CLAW_LLM_MODEL` route), with authentication behind a **separate `LLMCredentialSource` seam** — `docs/ARCHITECTURE.md` §8. **Telegram = a thin roll-your-own client** over AsyncHTTPClient, not a third-party lib.
- **MCP = client only — the official SDK for the wire format, our own transport.** `ClawMCP` speaks Streamable HTTP over the shared `HTTPExecuting`/`HTTPStreaming` seam, never the SDK's `HTTPClientTransport` (URLSession; no SSE on Linux). A remote tool is an ordinary `Tool` at `.ask` by default and `.arbitraryDestination` with untrusted results; a named `.safe` override removes the default tap but not the exfiltration gate. No gate, FSM, or fingerprint code learns the word MCP — `docs/ARCHITECTURE.md` §10.3.
- **Persistence = GRDB + SQLite (WAL, FTS5)**; secrets via `SecretStore` (swift-crypto AES-GCM envelope + a local `0600` key), **not** the macOS Keychain — a launchd daemon cannot reach it.
- **Store errors are domain-typed at the seam.** GRDB stores use `writer.writeMapping`/`readMapping` (not raw `write`/`read`), routing SQLite failures through `ClawDatabase.classifyError` into `StoreError` (e.g. `SQLITE_FULL → .diskFull`) — a raw `DatabaseError` must never leak past a store.

## Code style

- **Lint gate = `scripts/lint.sh`** over `Sources`, `Tests`, `Package.swift` — Apple swift-format owns general layout (`.swift-format`: 2-space, width 100, one-arg-per-line), the targeted SwiftFormat pass owns layout rules Apple cannot express (`BuildTools/guard-bodies.swiftformat`), and SwiftLint owns correctness/idiom (`.swiftlint.yml`). Run `scripts/lint.sh --fix` to auto-apply all fixes, then `scripts/lint.sh` to check; both must pass before committing (CI enforces it).
- **Wrapped conditions:** `swiftlint --fix` and `swift format` disagree on the `{` of a multi-line `if let X, cond {` (the gate then fails) — use `guard … else {` (brace attaches to `else`) or keep the condition single-line; if the single line would exceed width 100 (another case `--fix` never converges on), hoist a subexpression into a named local first.
- **Guard bodies are always multiline.** Never write `guard condition else { return }`; the targeted SwiftFormat pass expands it and the lint gate rejects it.
- **Names:** use descriptive identifiers; `.swiftlint.yml` `identifier_name` is the source of truth for the limits and for the domain exceptions it allows (`id`, `db`, `ts`, `ok`, `sh`).
- **Tests follow Given-When-Then** — separate the body with `// given` / `// when` / `// then` sections (AAA equivalent).
- **Comments: signal, not noise** — `///` states contract the signature can't express; `//` states a non-obvious *why*; never restate the code. Change history (task/increment/review tags) belongs to git, not comments.
- **Never cite internal spec coordinates in comments** — no bare `§N`; write the why in place, self-contained. Allowed pointers: stable external IDs (RFCs, vendor docs) or, only where code would otherwise read as a bug, the full form `ARCHITECTURE.md §N` — the durable direction is docs→code (see the `ARCHITECTURE.md` §3.1 code map).
- **Group private helpers into `private extension TypeName { }` blocks** by logical grouping, headed by a bare `// MARK: - <Group Name>` comment, no prose above it (see `RunCommand.swift`).

## Definition of done

SwiftPM commands: `swift build`, `swift test`, `swift test --filter <Suite>/<test>` for a single test. Build order and each increment's acceptance test → `docs/ARCHITECTURE.md` §20.

- While iterating, run the narrowest relevant `--filter` for fast feedback.
- Before calling a Swift change done — not merely before committing — run `scripts/lint.sh`, then `swift build`, then `swift test`.
- Re-read the final diff for unrelated edits, missing tests, documentation impact, and violations of the invariants above.
- Report which checks ran and what they printed. If one could not run, say so and why. Reading the code is not a substitute for the compiler, the test suite, or the lint gate.
