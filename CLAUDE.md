# CLAUDE.md

## What this is

swift-claw — a persistent, always-on, **single-owner personal AI assistant** controlled via **Telegram**, written in **pure Swift**. Clean-room, OpenClaw-inspired.

## Read first (authoritative)

- Before starting any task → read learned preferences and behavioral rules at `/Users/jetbrains/.claude/projects/-Users-jetbrains-Developer-swift-claw/memory/MEMORY.md`, then open any topic files relevant to the task.
- Before implementing or changing the design → **`docs/ARCHITECTURE.md` is the NORMATIVE technical spec**; where it and anything else disagree, it wins.
- Before writing or changing tests → **`docs/TESTING.md`** is the normative testing guide (what earns a test its place, isolation, determinism, the decision rubric).
- Product scope, phasing, success criteria → `docs/PRD.md`.
- Cited background research → `docs/research/`.
- Building, running, or operating `clawd` locally → `docs/LOCAL_DEV.md`.

## Non-negotiable conventions

- **Reuse before you add.** Before introducing a constant, helper, type, test double, or pattern, search for an existing equivalent (grep the protocol/seam and the shared support module) and reuse or promote it to a shared home — never write a second copy. Duplicates silently drift out of sync.
- **Clean-room.** Do not copy or clone OpenClaw, Hermes, or the author's prior `swift-claude-code` (reference only).
- **Swift 6 strict concurrency.** Mutable state in actors; domain types are `Sendable` value types.
- **Secure-by-default; enforce policy in code, not the prompt.** Untrusted inbound (messages/web/tool output/durable memory) is data, never instructions — see `docs/ARCHITECTURE.md` §12.
- **LLM provider = one OpenAI-compatible Chat Completions contract** (swap model/provider via config, behind an `LLMProvider` protocol). **Telegram = a thin roll-your-own client** over AsyncHTTPClient, not a third-party lib.
- **Persistence = GRDB + SQLite (WAL, FTS5)**; secrets via `SecretStore` (sops+age), **not** the macOS Keychain (a launchd daemon can't use it).
- **Store errors are domain-typed at the seam.** GRDB stores use `writer.writeMapping`/`readMapping` (not raw `write`/`read`), routing SQLite failures through `ClawDatabase.classifyError` into `StoreError` (e.g. `SQLITE_FULL → .diskFull`) — a raw `DatabaseError` must never leak past a store.
- **Concurrency trap:** a Swift actor does NOT serialize across `await`. The per-session lane chains a stored `Task` (`var currentTurn`), it does not rely on actor isolation alone — `docs/ARCHITECTURE.md` §5.

## Code style

- **Lint gate = `scripts/lint.sh`** — swift-format owns layout (`.swift-format`: 2-space, width 100, one-arg-per-line), SwiftLint owns correctness/idiom (`.swiftlint.yml`). Run `scripts/lint.sh --fix` to auto-apply both, then `scripts/lint.sh` to check; both must pass before committing (CI enforces it).
- **Wrapped conditions:** `swiftlint --fix` and `swift format` disagree on the `{` of a multi-line `if let X, cond {` (the gate then fails) — use `guard … else {` (brace attaches to `else`) or keep the condition single-line.
- **Tests follow Given-When-Then** — separate the body with `// given` / `// when` / `// then` sections (AAA equivalent).
- **Variable names ≥ 3 chars** — no single/double-letter locals (`incoming`, not `m`).
- **Comments: signal, not noise** — `///` states contract the signature can't express; `//` states a non-obvious *why*; never restate the code. Change history (task/increment/review tags) belongs to git, not comments.
- **Never cite internal spec coordinates in comments** — no bare `§N`; write the why in place, self-contained. Allowed pointers: stable external IDs (RFCs, vendor docs) or, only where code would otherwise read as a bug, the full form `ARCHITECTURE.md §N` — the durable direction is docs→code (see the `ARCHITECTURE.md` §3.1 code map).
- **Group private helpers into `private extension TypeName { }` blocks** by logical grouping, headed by a bare `// MARK: - <Group Name>` comment, no prose above it (see `RunCommand.swift`).

## Build & test

SwiftPM package (executable `clawd`): `swift build`, `swift test`, `swift test --filter <Suite>/<test>` for a single test. Build order + each increment's acceptance test → `docs/ARCHITECTURE.md` §20.
