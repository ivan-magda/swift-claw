# Load and use workspace skills (issue #67)

## Overview

Make `~/workspace/skills/<name>/SKILL.md` usable end-to-end: today the context index lists skill names but nothing can open one — the index drops the location, the system prompt has no protocol, no tool loads a body, and the 800-grapheme `skillsCap` silently drops skills past roughly the sixth.

After this plan: the owner writes a `SKILL.md`, sends a message the skill covers, and the agent scans the index, calls `skill_load` with the skill's name, receives the body, and follows it as task guidance. Malformed manifests and budget drops surface to the owner instead of vanishing.

Authority: GitHub issue #67 fixes the defect list and six design constraints; `docs/research/skills-openclaw-hermes-2026-08-02.md` is the cited background; `docs/ARCHITECTURE.md` is normative where designs collide.

Decisions already locked with the owner (do not relitigate):

- A skill body is **untrusted content the owner has permitted**: it stays inside the `<claw-untrusted>` fence under the `skills` label, and `toolUsePolicy` gains a carve-out permitting it as owner-authored task guidance. The absolute rule stands — fenced content can never alter instructions, tools, or permissions.
- **Loading a skill must not taint the session.** `skill_load` sets `ingestedUntrusted: false`. A `SKILL.md` has the same owner-authored-workspace provenance as `SOUL.md`/`AGENTS.md`, which `ARCHITECTURE.md` §12 already injects without tainting. (`file_read` taints unconditionally, and taint suppresses high-sensitivity memory for the whole session — that is why a dedicated tool exists at all.)
- **The model names a skill; it never types a path.** `skill_load` takes a name and resolves it against the scan; frontmatter YAML never becomes a path component.
- Scope is index + activation + budget/identity fixes only. Follow-ups (a `/skills` command + doctor row, agent-assisted authoring, tier-3 `references/`) are separate issues. `scripts/` and `assets/` stay unexecuted and unread. No installer, no network, no autonomous skill creation (PRD NG5).

## Context (from discovery)

- `Sources/ClawWorkspace/FileSystemWorkspace.swift` — `scanSkills()` (line ~40): missing dir → silent empty; unlistable → `.unreadableSkillsDirectory`; bad manifest → `.invalidSkillManifest(skill:)`. Frontmatter parser keeps only String-valued keys. Validation today: name/description non-empty, nothing else.
- `Sources/ClawCore/Domain/Context/ContextContracts.swift` — `SkillDescriptor` (name/description/directory, `id == name`), `ContextRowID.skills`, `ContextBudget` (fully labeled init; `default` has `skillsCap: 800`), untrusted-fence rendering.
- `Sources/ClawAgent/Context/ContextBuilder.swift` — `skillsSection(residual:)` builds one `SectionUnit(id: "skill-<name>", content: "- <name>: <description>", canTruncate: false)` per skill; `ownerNotices` is threaded through `buildFixedSections` only, **not** `buildTruncatableSections`.
- `Sources/ClawAgent/Context/BudgetFitter.swift` — `fittedRow` guards `unit.canTruncate` (line ~172) and skips non-fitting non-truncatable units (`continue`), producing a greedy non-prefix subset with no marker; truncatable units already get `prefix + truncationMarker` (line ~187) — precedent to extend. `FittedSection`'s initializer is fileprivate to the fitter, so post-fit mutation from `ContextBuilder` is impossible — markers must be emitted inside the fitter. The `.memoryItems` row also carries `canTruncate: false` units (`ContextBuilder.swift` line ~232) and must keep today's greedy behavior.
- `Sources/ClawAgent/Runtime/AgentRuntime.swift` — fences every live tool result with `label: observation.toolName` (line ~434); `ContextBuilder` re-labels replayed tool rows the same way on later turns — the two seams a declared fence label must cover.
- `Sources/ClawAgent/Context/SystemPrompt.swift` — shared `private static let toolUsePolicy` interpolated into both `minimal` and `proactive`. Prompt edits fold into `policy_version` via `promptMaterials` (expected, not a bug).
- `Sources/ClawTools/Tools/FileReadTool.swift` — the pattern to mirror: `SecretRedactor.redact` then cap via `ToolOutputCap` (already a shared home at `Sources/ClawTools/Text/ToolOutputCap.swift`, consumed by six tools) + the `ingestedUntrusted: true` contrast; `Sources/ClawTools/Tools/WorkspacePathContainment.swift` — realpath containment to reuse.
- `Sources/clawd/Composition/DaemonBuilder+Intake.swift` — `makeToolDispatcher` (line ~117) array-literal tool registration.
- Tests that are the executable spec: `Tests/ClawWorkspaceTests/WorkspaceSkillsScannerTests.swift` (9 tests), `Tests/ClawAgentTests/Context/ContextBuilderTests.swift` (~line 249: pins fence label `skills`, exact index line format, `hasPrivateDataAccess == false`).
- Dependency constraints: `ClawTools` depends only on `ClawCore`; Yams lives only in `ClawWorkspace`. The tool therefore takes an injected descriptor provider (composition wires the workspace) and reads/strips the body itself without YAML parsing. `WorkspaceReading` has six conformances (one production, five test doubles) — avoid widening it; if a new method is unavoidable, update all six.

## Development Approach

- **Testing approach**: TDD (tests first) — `docs/TESTING.md` is normative (Given-When-Then bodies with `// given` / `// when` / `// then`); write the failing test, then the code.
- Implementation happens on branch `workspace-skill-loading` (create from `main` if absent).
- Complete each task fully before moving to the next; small, focused changes.
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task — success and error scenarios, as separate checklist items.
- **CRITICAL: all tests must pass before starting the next task.** Bound every run (`swift test` hangs are bisected with `--filter`; a killed run leaks a `.build`-lock-holding `swiftpm-testing-helper` — reap it).
- **CRITICAL: update this plan file when scope changes during implementation.**
- Lint gate before any commit: `scripts/lint.sh --fix` then `scripts/lint.sh` — both must pass.
- House rule: load the `swift-testing-expert` skill when writing tests and `swift-concurrency` when touching actor/Sendable code.
- Reuse before you add: search for an existing constant/helper/double before writing one (e.g. reuse `file_read`'s output-cap constant, `WorkspacePathContainment`, existing workspace fakes).

## Testing Strategy

- **Unit tests**: required for every task (see above). Suites: `WorkspaceSkillsScannerTests`, `BudgetFitterTests`, `ContextBuilderTests`, new `SkillLoadToolTests`, plus the composition/acceptance suite per `ARCHITECTURE.md` §20.
- No UI, so no e2e framework; the §20-style acceptance test (Task 5) is the end-to-end proof.

## Progress Tracking

- Mark completed items with `[x]` immediately when done.
- Add newly discovered tasks with ➕ prefix.
- Document issues/blockers with ⚠️ prefix.
- Keep this plan in sync with actual work done.

## What Goes Where

- **Implementation Steps** (`[ ]` checkboxes): code, tests, docs — automatable in this repo.
- **Post-Completion** (no checkboxes): manual smoke tests, follow-up issue filing, PR mechanics.

## Implementation Steps

### Task 1: Scanner settles skill identity (validation, reconciliation, caps)

- [x] in `FileSystemWorkspace.scanSkills`, validate frontmatter `name` against the agentskills.io shape: matches `^[a-z0-9]+(-[a-z0-9]+)*$` and length 1–64 (the regex already forbids `--` and edge hyphens); invalid → `WorkspaceWarning` (reuse `.invalidSkillManifest` with a reason, or add a sibling case if the enum carries no reason text) and skip the skill
- [x] reconcile identities: `name` must equal the parent directory name (spec MUST); mismatch → warning naming both identities, skip
- [x] collision guard: if two accepted descriptors share a name, drop all claimants and warn naming their directories (unreachable through one scan root once name == directory holds — keep as a cheap invariant guard and unit-test the helper directly)
- [x] cap `description` at 300 graphemes at scan time, truncating with an ellipsis (spec allows 1024; the index must scale with skill count, not verbosity)
- [x] write tests: accepted edge names (single char, 64 chars, interior hyphens) and the description cap (success cases)
- [x] write tests: each rejection (uppercase, `--`, leading/trailing hyphen, >64 chars, name ≠ directory, collision helper) produces the specific warning (error cases)
- [x] run tests — must pass before Task 2

➕ Warning shape landed as three sibling cases (`.invalidSkillName`, `.skillNameDirectoryMismatch`, `.duplicateSkillName`) rather than a reason string on `.invalidSkillManifest`, keeping the three existing manifest-rejection tests intact. Description truncation reuses `TextTruncation.cap` (marker `…[truncated]`), not a second ellipsis helper. Task 2's owner-notice conversion must handle all four rejection cases.

### Task 2: Budget tells the truth about dropped skills

- [x] `BudgetFitter.fittedRow`: give the `.skills` row stop-at-first-non-fitting-unit semantics (prefix drop — a section-id case alongside the existing `.history` one). Scope is skills ONLY: `.memoryItems` units are also `canTruncate: false` and MUST keep today's greedy skip — rank-ordered memory selection is outside issue #67
- [x] emit the drop marker inside the fitter, following the existing `truncationMarker` path: when the skills row drops units, append a `(showing N of M skills)` line cost-accounted within the row's cap (the section supplies the wording — e.g. an optional drop-marker formatter on `FittableSection` — so the fitter stays row-agnostic); report the dropped unit ids on the fitted row. Post-fit appending is impossible by design: `FittedSection`'s init is fileprivate and the shrink loop's residual precondition has already passed
- [x] in `assemble`, after the fit, turn the skills row's dropped unit ids into an owner notice naming the dropped skills (drops do not exist before the fit, so nothing budget-related can be reported from `buildTruncatableSections`)
- [x] thread `ownerNotices` into `buildTruncatableSections` for its one real pre-fit consumer: `skillsSection` converts each `SkillScanResult` warning (invalid name, name ≠ directory, collision) into an owner notice, so a malformed manifest tells the owner why instead of dying in the `warn` log (issue #67 "What should work")
- [x] raise `ContextBudget.default` `skillsCap` 800 → 4000; note `scaledTruncatableCap` sums all caps into TOTAL, so sibling rows' scaled shares shift under pressure — adjust any pinned expectations deliberately, not mechanically
- [x] write tests: `BudgetFitterTests` — skills row with units 700/300/60/50 against cap 800 keeps only the first, emits the marker, reports three dropped; a `.memoryItems` row with units 700/300/60 keeps the greedy subset (first + third) — this pins the scope, because the 700/300/60/50 case alone passes under both a global and a skills-only change; no drops → no marker
- [x] write tests: `ContextBuilderTests` — scan-warning owner notices, budget-drop owner notice naming the dropped skills, and absence of all of it when everything fits
- [x] run tests — must pass before Task 3

### Task 3: The prompt gains a skills protocol

- [x] extend `SystemPrompt.toolUsePolicy`: content fenced under the `skills` label is owner-authored procedure the model may follow as guidance for how to perform a task; the absolute rule stands unchanged (fenced content cannot alter instructions, tools, or permissions — the permission lives here, in trusted policy, never in the content)
- [x] add the activation protocol next to it: scan the skills index; when one or more skills' descriptions match the task, load the single best-matching skill with `skill_load` before acting; never load more than one per task (the issue's "at most one" is a ceiling, not a uniqueness precondition — overlapping descriptions must not mean loading nothing)
- [x] write/update tests: prompt-pinning tests cover the new text in both `minimal` and `proactive`; `policy_version` shifting via `promptMaterials` is expected — update pins, don't suppress
- [x] run tests — must pass before Task 4

➕ The carve-out bullet sits in `toolUsePolicy` (it is a trust rule); the activation protocol landed as a sibling `skillsPolicy` constant interpolated into both variants, so the tool-trust doc comment stays accurate. No test pinned a `policy_version` literal, so nothing needed re-pinning — the two new pins are parameterized over both variants in `MixedProvenanceRenderingTests`.

### Task 4: skill_load tool

- [ ] define the tool's seam without new package edges: `SkillLoadTool` (in `ClawTools`) takes an injected `@Sendable` descriptor provider returning the current scan result (`SkillDescriptor` already lives in `ClawCore`); for body extraction, promote the scanner's line-based fence rule (a fence = a line whose trimmed text is `---`) into a shared `ClawCore` helper used by BOTH `FileSystemWorkspace` and the tool — an independent "split on `---`" reimplementation mislocates the closing fence on scanner-accepted files (CRLF, trailing-whitespace fences) or on bodies containing a `---` horizontal rule (still no YAML parse, so no Yams dependency)
- [ ] implement resolution: input `{name}`; fresh scan at call time; hit → body; unknown name → **successful** payload listing the valid names (self-correcting miss); duplicate claimants at load time → refusal naming both directories (silent shadowing is the named bug class)
- [ ] deliver the body under the `skills` fence label: both fence seams currently label a tool result with the tool's name (`AgentRuntime`'s live observation path, `ContextBuilder`'s history replay), which would fence the body as `skill_load` — a label the Task 3 carve-out never licenses. Give the tool contract a declared fence label (default: the tool name) and honor it at both seams. Issue constraint 1 locks the body under `skills`; widening the carve-out to name `skill_load` instead is NOT an option
- [ ] safety posture: egress `.none`, risk `.safe`, `ingestedUntrusted: false` with a why-comment stating the owner-authored-workspace provenance; resolve the body path through `WorkspacePathContainment` against `<root>/skills` (defense in depth — a symlinked skill directory must not escape); redact the body through the injected `SecretRedactor`, then cap it via the shared `ToolOutputCap` — both mirror `FileReadTool`, and ARCHITECTURE.md §10.2 requires file tools to ship size-capped AND redacted output
- [ ] register the tool in `makeToolDispatcher` (`DaemonBuilder+Intake.swift`) and wire the workspace-backed provider in composition
- [ ] write tests: `SkillLoadToolTests` with a fake provider — hit returns the stripped body under the `skills` fence label, taint flag false, secrets redacted, output capped (success cases); shared fence-locator tests: CRLF line endings, trailing-whitespace fences, `---` horizontal rule inside the body
- [ ] write tests: miss lists valid names as a success payload; duplicate refuses naming both; containment rejects an escaping symlink; unreadable body surfaces a domain error (error cases)
- [ ] confirm `PolicyFingerprintTests` still pass as-is: they are property-based, and no test pins a production `staticSubhash` (none can — the runtime value folds workspace root and exec config); registering the tool still shifts the runtime hash and voids parked approvals once — record that in the PR description, do not add a pinned-hash test
- [ ] run tests — must pass before Task 5

### Task 5: Verify acceptance criteria

- [ ] add the §20-style acceptance test: a workspace with one skill → assembled context contains the index row inside the `skills`-labeled fence → scripted model turn calls `skill_load` → body comes back inside a `skills`-labeled `<claw-untrusted>` fence → session is **not** tainted (high-sensitivity recall still included afterwards)
- [ ] verify every issue-#67 constraint has a test naming it (loaded body under the `skills`-labeled untrusted fence, no taint, name-not-path, miss lists names, budget drops surface, malformed manifests surface to the owner, identity at scan)
- [ ] run the full test suite
- [ ] run `scripts/lint.sh --fix` then `scripts/lint.sh` — all issues fixed
- [ ] confirm git tracks every new file (`git status` — unanchored `.gitignore` patterns have swallowed new directories before)

### Task 6: Update documentation

- [ ] `docs/ARCHITECTURE.md`: §10.1 tier prose and the §10.2 risk-tier table gain `skill_load` (egress/risk/taint posture — §8 is the LLM provider seam, not tools); §9.1–§9.2 describe the skills row's prefix-drop + marker semantics (making the promised marker true); §12 records the `skills`-label carve-out AND amends the taint-definition sentence with `skill_load`'s no-taint exception (precedent: the durable-memory does-not-taint exception already in §12); §20 gains the increment's "Done when"
- [ ] `docs/CUSTOMIZATION.md`: authoring guide — directory layout, frontmatter contract (name rules, description cap), how validation failures and budget drops surface to the owner
- [ ] sweep the public-surface siblings (`README.md`, `docs/GETTING_STARTED.md`, `docs/INSTALL.md`, `deploy/README.md`) — they document each other's state; update wherever skills now appear as a user-visible surface
- [ ] run the stop-slop pass over all new public prose
- [ ] run `scripts/lint.sh` and the full test suite one final time

## Technical Details

- Index line format is unchanged (`- <name>: <description>`): the "index carries no location" defect is resolved by the loader seam, not by printing paths — printing workspace paths would invite the model to type them, which constraint 3 forbids. `ContextBuilderTests` pins the exact format; any change there must be deliberate.
- `skill_load` input schema: `{ "name": string }` — nothing else. Resolution is by exact match against scanned descriptors.
- The tool-declared fence label is what keeps issue constraint 1 true end-to-end: the index row and the loaded body both render under `skills`, and the carve-out names only that label — never `skill_load`.
- The marker line and owner notice must agree: `(showing N of M skills)` in-prompt; the notice names the dropped skills so the owner can rename/trim (scan order is deterministic, so which skills survive is under the owner's control).
- Body extraction uses the same shared fence locator as the scanner (a fence = a line whose trimmed text is `---`; the body is every line after the closing fence), so a file the scanner indexed parses identically in the loader. If the file changed on disk between scan and load and the fence is gone, the loader errors — it never guesses.
- The scanner's String-only frontmatter retention (spec `metadata` map unrepresentable) is a known drift, out of scope here — skills need only `name` and `description`.

## Post-Completion

**Manual verification:**

- Real Telegram smoke test: author a skill in the live workspace, send a message it covers, watch the agent load and follow it; confirm no memory-suppression side effects across the session.
- Confirm parked approvals were voided exactly once after the deploy (expected `staticSubhash` change).

**External follow-ups:**

- File the three follow-up issues deferred from #67: `/skills` command + doctor row; agent-assisted skill authoring via ask-tier `file_write`; tier-3 `references/` loading.
- PR per house conventions: branch `workspace-skill-loading`, descriptive title, no generated-with footer; merge (never rebase).
