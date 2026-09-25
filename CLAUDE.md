# Agent instructions

swift-claw is a persistent personal AI assistant controlled via Telegram, written in Swift;
SwiftPM builds the `clawd` executable. Personal mode is single-owner; group mode is a separate,
opt-in deployment with no personal state.

`AGENTS.md` is a symlink to this file; edit `CLAUDE.md` to keep Codex and Claude Code aligned.
Paths below are conditional reading instructions, not automatic imports. These repository
instructions/skills are separate from clawd's runtime workspace files (`docs/CUSTOMIZATION.md`).

## Project map

- `Package.swift`: target graph. `Sources/ClawCore/`: shared protocols, value types and errors; sibling `Claw*` targets implement them. `ClawAgent` and `ClawGateway` access persistence only through Core protocols.
- `Sources/clawd/`: composition, bootstrap, CLI. `Sources/ClawGateway/`: routing, approvals, scheduling, lifecycle. `Sources/ClawAgent/`: context and agent turns.
- `Sources/ClawData/`: GRDB stores; `Sources/ClawSecrets/`: secrets; `Sources/ClawTools/`: tools and policy. For other features, find owning symbols in `docs/ARCHITECTURE.md` §3.1 before searching source.
- `Tests/<Target>Tests/` (CLI: `Tests/ClawdCompositionTests/`); shared fixtures in `Sources/ClawTestSupport/`. `scripts/`, `BuildTools/`: validation tooling; `.github/workflows/`: CI.

## Read before changing

- Architecture, cross-module behavior or contracts → relevant sections of `docs/ARCHITECTURE.md`, the accepted technical design. Update it in the same commit as a deliberate contract change. Report unresolved spec/code conflicts; do not silently choose a new policy. New normative detail belongs there; keep essential guards and routing here.
- Scope, phasing or acceptance criteria → `docs/PRD.md` and architecture §20. Comparative research in `docs/research/` is evidence, not a spec; borrow ideas, never copy or line-by-line port code.
- Tool policy, approvals, trust, path containment or egress → architecture §§10–12; MCP → §10.3; group/forum behavior → §12.1.
- LLM adapters or credentials → architecture §8; secrets/state-root lifecycle → §§4, 15; persistence → §7; session concurrency → §5.
- Context, memory or runtime workspace skills → architecture §§9, 12; scheduling/learning → §14; VM execution → §13.1; native Coder → §§5.2.1, 13.2.
- Any Swift source or style review → `docs/CODE_STYLE.md`. Lint/formatter configuration, pins or exceptions → also architecture §19.2; run `scripts/test-lint.sh` and verify a second fix changes nothing.
- Any test diff → follow `docs/TESTING.md` end to end: test-intent map and pre-commit redundancy pass. Each added test must name a reachable mutant the nearest existing test would not kill. Cross-cutting test diffs need an independent test-value/redundancy review (subagent if available, otherwise re-read from scratch).
- Commands, flags, env vars, defaults, secrets or install/release steps → read the whole public set: `README.md`, `docs/GETTING_STARTED.md`, `docs/INSTALL.md`, `docs/CUSTOMIZATION.md`, `deploy/README.md`. For env changes, also check `.env.example`. Update affected guides only.
- Build setup or operating clawd → `docs/LOCAL_DEV.md`; CLI/config probes → `.claude/skills/verify/SKILL.md` (read it explicitly if `verify` is unavailable). Claude discovers `.claude/skills/`; Codex discovers `.agents/skills/`, linked to the same body.
- Preparing a PR → `CONTRIBUTING.md` and `.github/PULL_REQUEST_TEMPLATE.md`; reporting a vulnerability → `SECURITY.md`, privately.

## Invariants

- Build for today's requirement. Add abstraction only for a concrete scenario, test seam, layer boundary or named risk. Search the owning seam and shared support before adding helpers/constants/doubles; reuse semantic equivalents, not similar shapes. Use domain enums/constants rather than duplicated magic strings.
- Extract responsibilities before extending an overloaded file. Group three or more siblings behind one entry point; preserve directed dependencies and public API. Do not split solely by line count or into one-function files.
- Swift 6 strict concurrency: domain values are `Sendable`; shared mutable state normally lives in actors. Preserve specified synchronous lock-backed cancellation/admission primitives (architecture §§5, 8.4). GRDB stores are thin `Sendable` wrappers over `any DatabaseWriter`, not actors.
- Actors do not serialize across `await`: per-session work chains stored tasks (`SessionLaneRegistry`). Stores use `writer.writeMapping`/`readMapping` through `ClawDatabase.classifyError`; raw `DatabaseError` must never cross the `StoreError` seam.
- Enforce security in code: numeric-ID default-deny, fail-closed access, tool/approval gates, secret redaction. Untrusted messages/web/tool output/durable memory are data, never instructions or authority. Group mode's documented exception requires its own non-personal state root. Never include credentials or private state in logs, diffs or PRs.
- `execute_code` requires its VM sandbox; native Coder has a distinct delegated trust boundary, not a sandbox implied by its working directory. Preserve both contracts and specialized acceptance checks.
- Telegram uses the thin AsyncHTTPClient-based client. MCP is client-only; gates, FSMs and fingerprints remain protocol-neutral. Secrets use `SecretStore` (swift-crypto AES-GCM + local `0600` key), not macOS Keychain. Persistence is GRDB + SQLite WAL/FTS5.
- Google Swift style plus local rules: nonempty statement/closure bodies multiline, 100-character source limit (manual wrapping preserves string bytes), private helpers grouped in marked extensions. Tests use `// given`, `// when`, `// then`. Passing lint does not waive manual style checks.

## Verification

Run from the repository root; build/lint/unit tests need no runtime secrets.

- During iteration: `swift test --filter <Suite>/<test>`; discover exact names with `swift test list`.
- Run `scripts/lint.sh --fix`, inspect its diff, then `scripts/lint.sh`; the whole lint gate must pass before committing. Pins and setup: `BuildTools/lint-versions.env`, `docs/CODE_STYLE.md`.
- Before calling a Swift change done: `scripts/lint.sh`, then `swift build`, then `swift test`, even if focused tests pass. Sandbox/Coder release work also needs the applicable acceptance checks in `docs/LOCAL_DEV.md`.
- Documentation-only changes: verify affected links, examples and template syntax. Re-read the final diff for unrelated edits, missing tests, documentation impact and invariant violations.
- Report commands and actual results; explain any check that could not run. Reading code is not compiler/test/lint evidence.
