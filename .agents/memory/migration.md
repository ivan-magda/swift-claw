# Claude memory migration, 2026-10-05

Reviewed 39 topic notes and their `MEMORY.md` index from the maintainer's Claude Code project
memory. The shared notes now live here and use ordinary Markdown links. Session IDs, repeated
incident narratives, and private deployment identifiers are not part of the tracked memory.

The root `AGENTS.md` remains a symlink to `CLAUDE.md`; both agents receive the same reading rule.
Project settings disable Claude auto memory. The original directory is preserved locally as
`memory.migrated-2026-10-05` beside its former location, outside the active `memory/` path.
That archive is a recovery copy, not a second active source of project guidance.

## Disposition of every source note

Filenames below identify migration inputs; they are not files to recreate in this directory.
“Consolidated” retains the applicable lesson without the original session narrative.

| Original note | Destination or disposition |
| --- | --- |
| `announce-before-applying-agent-results.md` | [Collaboration](collaboration.md), communication |
| `apple-speech-multilocale-facts.md` | [Technical history](technical-history.md), dated speech observations |
| `authoring-public-swift-packages.md` | Optional local notes; conventions for other repositories, some incompatible with this repo's style |
| `commit-where-told.md` | [Collaboration](collaboration.md), Git |
| `defaulted-di-params-not-dead.md` | [Collaboration](collaboration.md), dependency seams |
| `descriptive-branch-pr-names.md` | [Collaboration](collaboration.md), Git |
| `doc-fixes-cascade.md` | [Collaboration](collaboration.md), documentation |
| `dont-revert-unexplained-tree-changes.md` | [Collaboration](collaboration.md), Git |
| `feedback-plan-summary-format.md` | [Collaboration](collaboration.md), communication |
| `feedback-threat-model-scoping.md` | [Collaboration](collaboration.md), reachable findings and deployment scope |
| `fetch-before-resuming-pr-work.md` | [Collaboration](collaboration.md), Git |
| `github-hash-number-autolink.md` | [Collaboration](collaboration.md), GitHub prose |
| `inc5b-sandbox-spike-facts.md` | [Technical history](technical-history.md), sandbox; current contract linked |
| `invoke-swift-domain-skills.md` | [Collaboration](collaboration.md), task execution |
| `layerb-real-runs-wedge-at-exit.md` | [Verification](verification.md), retired 0.5.0 workaround |
| `local-group-instance-layout.md` | Optional local notes; private identifiers excluded from Git |
| `no-nits-in-reviews.md` | [Collaboration](collaboration.md), substantive reviews |
| `normative-docs-hold-principles.md` | [Collaboration](collaboration.md), documentation |
| `pin-actions-to-version-tags.md` | [Collaboration](collaboration.md), existing ref-pin policy |
| `podlodka-group-mode-decisions.md` | [Technical history](technical-history.md), superseded by architecture §12.1; expired event logistics archived |
| `readability-over-microopt.md` | [Collaboration](collaboration.md), readability |
| `repo-going-public.md` | [Collaboration](collaboration.md), external adopters and release authorization; old CI versions retired |
| `research-docs-land-on-main.md` | [Collaboration](collaboration.md), standalone docs and explicit Git authorization |
| `sdd-cost-is-round-trips.md` | [Collaboration](collaboration.md), efficient execution; old timings are not current budgets |
| `sdd-ledger-unique-anchors.md` | [Collaboration](collaboration.md), scoped ledger edits |
| `sdd-task-brief-drops-preamble.md` | [Collaboration](collaboration.md), full-plan constraints |
| `stop-slop-github-prose.md` | [Collaboration](collaboration.md), final prose review |
| `swift-speech-lanes-package.md` | [Technical history](technical-history.md), extraction and obsolete macOS-floor rationale |
| `swift-ssrf-guard-package.md` | [Technical history](technical-history.md), independent classifier copies |
| `swiftlint-disable-anchoring.md` | [Verification](verification.md), diagnostic locations; current style guide linked |
| `telegram-draft-streaming-facts.md` | [Technical history](technical-history.md), tracked report and merged change; raw-material location in local notes |
| `test-cooperative-thread-blocking.md` | [Verification](verification.md), low-core reproductions; current TESTING.md linked |
| `test-runs-bounded-and-bisected.md` | [Verification](verification.md), deadlines and cleanup limited to owned processes |
| `test-timings-starvation-inflated.md` | [Verification](verification.md), contention and isolated measurement |
| `user-bilingual-russian.md` | [Collaboration](collaboration.md), reply language; speech fixture context in technical history |
| `verify-against-source.md` | [Verification](verification.md), full-path evidence |
| `verify-new-files-tracked.md` | [Collaboration](collaboration.md), Git visibility |
| `verify-the-experiment-ran.md` | [Verification](verification.md), independent setup checks |
| `write-in-ste-russian.md` | [Collaboration](collaboration.md), plain Russian replies |

## Corrections made during review

- [Package.swift](../../Package.swift) targets macOS 26 and pins swift-subprocess 1.0.0.
  The older floor and subprocess-exit workaround no longer describe the build.
- [Architecture §12.1](../../docs/ARCHITECTURE.md#121-group-mode-config-gated-off-by-default)
  includes group Coder approval and membership checks. The August planning note is not its spec.
- The Telegram latency report is tracked and PR 240 landed the early-second-draft change.
  Its original “untracked” and “not pushed” labels are historical.
- Other-package formatter conventions do not apply here. The current
  [style guide](../../docs/CODE_STYLE.md) governs swift-claw.
- Old blanket process-kill advice and automatic push recipes were narrowed to owned resources
  and the action authorized by the current task.

The migration changes development notes and agent settings only. It does not change the daemon's
runtime memory, code, product contracts, or deployment configuration.
