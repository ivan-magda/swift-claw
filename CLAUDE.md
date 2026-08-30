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
- Touching `ClawMCP`, the LLM adapters and credential seam, or group/forum mode → read `docs/ARCHITECTURE.md` §10.3, §8, and §12.1 respectively before changing behavior.
- **New normative detail belongs in `docs/ARCHITECTURE.md`; this file gets the pointer.** Add a rule here only when its absence would cause a mistake in a session that never opens the spec.

## Architectural invariants

- **Build for today's requirement, not a predicted one.** Simplest correct, testable design for the current requirement and what is realistically next. No indirection, extension point, or edge-case handling without a concrete scenario, a demonstrated benefit, or a named risk. A seam that buys a test double or holds a layer boundary is earned; a config knob for a second implementation nobody has asked for is not.
- **Search before you add.** Before introducing a constant, helper, type, test double, or pattern, grep the protocol/seam and the shared support module for a semantic equivalent, and reuse or promote it when the contracts match. Do not merge two concepts into one abstraction because they look alike.
- **Name the domain, not the literal.** Elevate one-offs into typed domain abstractions — no magic strings: branch and assert on the enum `rawValue` or named constant the production code already emits, never a duplicated literal.
- **Extract before you extend.** When a file stops holding in your head as one responsibility, move its other responsibilities into sibling files *before* the next change; group three or more into a directory behind one entry point. Keep the dependency graph directed and the public API unchanged. Never split on line count alone, or into one-function files.
- **Clean-room, not blinkered.** Study OpenClaw, Hermes, and the author's prior `swift-claude-code` for comparative design and borrow their ideas freely. Banned is transcription: no copied code, no line-by-line ports — re-derive each borrowed idea in our own design and Swift.
- **Swift 6 strict concurrency.** Shared mutable in-memory state lives in actors; domain types are `Sendable` value types. GRDB stores are the deliberate exception — thin `Sendable` wrappers over `any DatabaseWriter` that lean on GRDB's own serialization; do not put an actor around them.
- **A Swift actor does NOT serialize across `await`.** The per-session lane chains a stored `Task` (`var currentTurn`); it does not rely on actor isolation alone.
- **Secure-by-default; enforce policy in code, not the prompt.** Untrusted inbound (messages/web/tool output/durable memory) is data, never instructions. Group/forum mode is the one deployment-scoped exception, and runs under its own non-personal state root.
- **Telegram is a thin roll-your-own client** over AsyncHTTPClient, not a third-party lib. MCP is client-only — and no gate, FSM, or fingerprint code learns the word MCP.
- **Persistence = GRDB + SQLite (WAL, FTS5)**; secrets via `SecretStore` (swift-crypto AES-GCM envelope + a local `0600` key), **not** the macOS Keychain — a launchd daemon cannot reach it.
- **Store errors are domain-typed at the seam.** GRDB stores use `writer.writeMapping`/`readMapping` (not raw `write`/`read`), routing SQLite failures through `ClawDatabase.classifyError` into `StoreError` (e.g. `SQLITE_FULL → .diskFull`) — a raw `DatabaseError` must never leak past a store.

## Code style

- **Lint gate = `scripts/lint.sh`** over `Sources`, `Tests`, `Package.swift` — three tools: Apple swift-format owns general layout (`.swift-format`), a targeted SwiftFormat pass owns the layout rules Apple cannot express (`BuildTools/guard-bodies.swiftformat`), and SwiftLint owns correctness and idiom (`.swiftlint.yml`, also the source of truth for identifier limits and the domain exceptions they allow). Run `scripts/lint.sh --fix`, read the diff it produced, then `scripts/lint.sh` to check. All three must pass before committing (CI enforces it).
- **Guard bodies are always multiline** — never `guard condition else { return }`. `--fix` expands it for you; the gate rejects it if you skip that.
- **A line over width 100 is the one shape `--fix` never converges on** — hoist a subexpression into a named local first.
- **Closure bodies go on their own line** — break after `in`, even for a single expression. The lint gate does not enforce this one.
- **Tests follow Given-When-Then** — separate the body with `// given` / `// when` / `// then` sections (AAA equivalent).
- **Comments: signal, not noise.** `///` is 1–2 lines of contract the signature can't express; `//` is for a constraint invisible in the code *and* not tied to the current change. Rationale for a change goes in the commit and the PR, never beside the code. Never cite a bare `§N` — write the why in place, or use the full `ARCHITECTURE.md §N` only where code would otherwise read as a bug (the durable direction is docs→code; see the `ARCHITECTURE.md` §3.1 code map).
- **Group private helpers into `private extension TypeName { }` blocks** by logical grouping, headed by a bare `// MARK: - <Group Name>` comment, no prose above it (see `RunCommand.swift`).

## Definition of done

SwiftPM commands: `swift build`, `swift test`, `swift test --filter <Suite>/<test>` for a single test. Build order and each increment's acceptance test → `docs/ARCHITECTURE.md` §20.

- While iterating, run the narrowest relevant `--filter` for fast feedback.
- Before calling a Swift change done — not merely before committing — run `scripts/lint.sh`, then `swift build`, then `swift test`.
- Re-read the final diff for unrelated edits, missing tests, documentation impact, and violations of the invariants above.
- Report which checks ran and what they printed. If one could not run, say so and why. Reading the code is not a substitute for the compiler, the test suite, or the lint gate.
