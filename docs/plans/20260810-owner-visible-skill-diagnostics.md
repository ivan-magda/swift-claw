# Owner-visible skill diagnostics

## Overview

Add a read-only `/skills` command that runs a fresh workspace scan and lists accepted skills with
their descriptions plus every rejection diagnostic. Add a `context.skills` health row to full
`clawd doctor` and Telegram `/status`, including accepted and rejected counts and whether the
complete index fits `skillsCap`. Update help, Telegram's command picker, normative specifications,
and public skill documentation.

## Context

- Files involved:
  - `Sources/ClawCore/Workspace/WorkspaceSkills.swift`
  - `Sources/ClawCore/Workspace/SkillScanResult.swift`
  - `Sources/ClawCore/Domain/Bot/Command.swift`
  - `Sources/ClawAgent/Context/ContextBuilder.swift`
  - `Sources/ClawGateway/Response/SkillDiagnostics.swift` (new)
  - `Sources/ClawGateway/Response/CommandReplies.swift`
  - `Sources/ClawGateway/Response/DoctorReporting.swift`
  - `Sources/ClawGateway/Response/HealthRowsBuilder.swift`
  - `Sources/ClawGateway/Routing/MessageRouter.swift`
  - `Sources/clawd/Composition/DoctorHealth.swift`
  - `Sources/clawd/Composition/DaemonBuilder+Doctor.swift`
  - `Sources/clawd/Composition/DaemonBuilder+Boot.swift`
  - Related tests under `Tests/ClawCoreTests`, `Tests/ClawAgentTests`,
    `Tests/ClawGatewayTests`, and `Tests/ClawdCompositionTests`
  - `README.md`, `docs/GETTING_STARTED.md`, `docs/CUSTOMIZATION.md`,
    `docs/ARCHITECTURE.md`, and `docs/PRD.md`
- Related patterns:
  - `SkillScanResult` already contains the accepted descriptors and scan warnings.
  - `ContextBuilder` owns the current index-line and warning wording; promote these rules to
    shared pure helpers instead of creating a second renderer.
  - `DoctorReporting` already supplies the live `/status` snapshot and can expose the same fresh
    scan to `/skills`.
  - `HealthRowsBuilder` owns shared CLI and daemon health rows.
  - `/mcp` provides the routing precedent for a read-only Telegram diagnostics command.
- Dependencies: no new external dependencies, persistence, tools, or mutable state.
- Health semantics:
  - The row key will be `context.skills`, grouped under `.context`, and marked as a Telegram
    headline.
  - `accepted` uses `descriptors.count`; `rejected` uses `warnings.count`, matching the two
    collections returned by the scanner.
  - The row fails when the scan reports a warning or the complete canonical index exceeds
    `skillsCap`.
  - Cap fit compares the exact canonical index text against the absolute `skillsCap`; it does not
    predict turn-specific residual-budget scaling.
- Out of scope:
  - No `clawd skills` CLI subcommand, skill installer, authoring workflow, or persistent skill
    registry.
  - No changes to skill validation, `skill_load`, references, scripts, or assets.
  - No automatic repair of rejected or over-budget skills.

## Development Approach

- **Testing approach**: TDD. Add each observable-behavior test before its implementation.
- Complete each task fully before moving to the next.
- Follow `docs/TESTING.md`: Given-When-Then sections, structural assertions for rendered text,
  real filesystem scans where scan behavior matters, and no call-order assertions.
- Reuse `SkillScanResult`, `WorkspaceSkills`, `EmptyWorkspace`, and the existing doctor/router test
  support.
- **CRITICAL: every task that changes code MUST include new or updated tests.**
- **CRITICAL: all tests for a task must pass before starting the next task.**

## Implementation Steps

### Task 1: Create canonical skill diagnostics and rendering

**Files:**

- Modify: `Sources/ClawCore/Workspace/WorkspaceSkills.swift`
- Modify: `Sources/ClawCore/Workspace/SkillScanResult.swift`
- Modify: `Sources/ClawAgent/Context/ContextBuilder.swift`
- Create: `Sources/ClawGateway/Response/SkillDiagnostics.swift`
- Create: `Tests/ClawCoreTests/Workspace/SkillDiagnosticsTests.swift`
- Create: `Tests/ClawGatewayTests/Response/SkillDiagnosticsTests.swift`
- Modify: `Tests/ClawAgentTests/Context/ContextBuilderTests.swift`

- [x] Promote the canonical `- <name>: <description>` index-line construction and complete-index
      grapheme calculation into `WorkspaceSkills`.
- [x] Promote the existing exhaustive `WorkspaceWarning` owner-facing reason text into a shared
      pure helper, including text for unreadable and outside-workspace skill directories.
- [x] Update `ContextBuilder` to use the shared line and warning helpers while preserving its
      current policy of logging, rather than repeatedly notifying, an unreadable `skills/`
      directory during ordinary turns.
- [x] Implement `SkillDiagnostics` to render deterministic Accepted and Rejected sections from one
      `SkillScanResult`, including explicit empty states and every warning returned by the scanner.
- [x] Derive accepted count, rejected count, and exact `skillsCap` fit from the same canonical
      helpers used by context assembly.
- [x] Add boundary tests for an index equal to the cap and one grapheme over it, plus structural
      renderer tests covering accepted skills, every warning case, duplicate claimants, and an
      empty scan.
- [x] Update `ContextBuilderTests` to prove automatic notices retain their behavior after the
      formatter moves.
- [x] Run the affected ClawCore, ClawAgent, and ClawGateway test suites; all must pass before
      Task 2.

### Task 2: Add the shared doctor and status skills row

**Files:**

- Modify: `Sources/ClawGateway/Response/DoctorReporting.swift`
- Modify: `Sources/ClawGateway/Response/HealthRowsBuilder.swift`
- Modify: `Sources/clawd/Composition/DoctorHealth.swift`
- Modify: `Sources/clawd/Composition/DaemonBuilder+Doctor.swift`
- Modify: `Tests/ClawGatewayTests/Support/StubDoctorReporter.swift`
- Modify: `Tests/ClawGatewayTests/Response/HealthRowsBuilderTests.swift`
- Modify: `Tests/ClawGatewayTests/Response/DoctorReportTests.swift`
- Create: `Tests/ClawdCompositionTests/SkillDiagnosticsCompositionTests.swift`

- [x] Extend the runtime diagnostics seam with a fresh `SkillScanResult` operation so `/skills`
      and `/status` read the workspace through one owner-diagnostics provider.
- [x] Have `DoctorHealth` scan `EnvironmentLoader.workspaceRoot(config:)` each time it builds full
      health inputs; keep `doctor --check-config` limited to its existing config and secret scope.
- [x] Add the `context.skills` headline check in `HealthRowsBuilder`, with accepted and rejected
      counts plus the cap-fit flag.
- [x] Mark the row unhealthy when warnings exist or the index does not fit, so full `clawd doctor`
      exits nonzero and `/status` expands the actionable row.
- [x] Update the daemon reporter and test stub to serve fresh or scripted scans.
- [x] Add row tests for no skills, accepted skills, warnings, exact-cap fit, and overflow; assert the
      healthy `/status` headline and failing detail without freezing full prose.
- [x] Add JSON assertions for the row's key, value fields, `ok`, `.context` group, and headline flag.
- [x] Add a composition test using a temporary workspace to prove a real scan reaches the daemon
      health report and changes after the workspace changes.
- [x] Run the affected ClawGateway and ClawdComposition tests; all must pass before Task 3.

### Task 3: Add `/skills`, help, and Telegram command discovery

**Files:**

- Modify: `Sources/ClawCore/Domain/Bot/Command.swift`
- Modify: `Sources/ClawGateway/Response/CommandReplies.swift`
- Modify: `Sources/ClawGateway/Routing/MessageRouter.swift`
- Modify: `Sources/clawd/Composition/DaemonBuilder+Boot.swift`
- Modify: `Tests/ClawCoreTests/Domain/Bot/CommandTests.swift`
- Modify: `Tests/ClawGatewayTests/Routing/MessageRouterTests.swift`
- Modify: `Tests/ClawGatewayTests/Routing/ScheduleInteractionTests.swift`
- Create: `Tests/ClawdCompositionTests/BotMenuCommandsTests.swift`

- [x] Add the `.skills` command and parse bare, case-insensitive, and matching-bot forms; treat an
      argument tail as the same read-only diagnostics request.
- [x] Route allowlisted `/skills` directly through `DoctorReporting` to a fresh scan and
      `SkillDiagnostics`; do not dispatch an LLM turn or write skill state.
- [x] Preserve default-deny behavior so non-allowlisted senders learn nothing about installed or
      rejected skills.
- [x] Add `/skills` to `CommandReplies.help` and Telegram's registered command picker.
- [x] Add parser and router tests proving fresh results, accepted and rejected output, no turn
      dispatch, duplicate-update handling, and unauthorized access control.
- [x] Add a menu test that verifies the registered catalog contains `/skills` with owner-facing
      diagnostic wording.
- [x] Update the existing help test to keep using `CommandReplies.help` as the copy owner rather
      than duplicating the full help text.
- [x] Run the affected ClawCore, ClawGateway, and ClawdComposition tests; all must pass before
      Task 4.

### Task 4: Verify acceptance criteria

**Files:**

- Verify: all production and test files changed in Tasks 1-3

- [x] Verify `/skills` lists every accepted descriptor and every scanner warning from a fresh scan.
- [x] Verify full `clawd doctor` and Telegram `/status` expose the same accepted count, rejected
      count, and cap-fit result.
- [x] Verify healthy skill diagnostics remain visible in `/status` as a headline and rejected or
      dropped skills fail the row.
- [x] Verify `clawd doctor --json` includes the complete `context.skills` check fields.
- [x] Run the full suite with `swift test`.
- [x] Run `scripts/lint.sh --fix`, then `scripts/lint.sh`; both must pass.
- [x] Run `swift test --enable-code-coverage`, locate the report with
      `swift test --show-code-coverage-path`, and confirm the changed diagnostic paths have at least
      80% line coverage.
- [x] Confirm Git tracks every new file with `git status --short`.

### Task 5: Update specifications and public documentation

**Files:**

- Modify: `docs/ARCHITECTURE.md`
- Modify: `docs/PRD.md`
- Modify: `README.md`
- Modify: `docs/GETTING_STARTED.md`
- Modify: `docs/CUSTOMIZATION.md`
- Review for consistency: `docs/INSTALL.md`
- Review for consistency: `deploy/README.md`

- [ ] Update the architecture code map, skills section, and observability table with `/skills`, the
      fresh-scan rule, `context.skills` fields, failure semantics, and absolute-cap interpretation.
- [ ] Update the PRD skills requirements and success criteria with on-demand diagnostics and
      doctor/status visibility.
- [ ] Update README skill discovery text to point owners to `/skills`.
- [ ] Update GETTING_STARTED so the sample skill can be checked with `/skills` and the doctor row is
      explained.
- [ ] Update CUSTOMIZATION's failure-surface section to distinguish automatic turn notices from the
      complete on-demand `/skills` view and the summarized doctor row.
- [ ] Sweep INSTALL and deploy documentation for command inventories or health-output claims;
      change them only if the new surface invalidates existing text.
- [ ] Run the stop-slop pass over new public prose.
- [ ] Run `swift test` and `scripts/lint.sh` after documentation changes; both must pass.
