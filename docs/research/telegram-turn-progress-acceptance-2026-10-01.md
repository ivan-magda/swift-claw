# Telegram turn progress: partial automated acceptance

Date: 2026-10-01. Issue: 239. Reviewed code commit:
`e108fe5e59d69dfe7db3f2e38b57ce4a2af5dde7` on `feature/239-telegram-turn-progress`.

The final automated gate passed after the final code edit. The owner deferred live provider,
Telegram, UI, end-to-end and recording acceptance until their return. Feature acceptance remains
incomplete pending those checks.

## Final repository gate

The executor ran these commands from the repository root, in this order, on macOS arm64 with
Apple Swift 6.4 (`swiftlang-6.4.0.34.1`, target `arm64-apple-macosx26.0`). `gtimeout` supplied the
available timeout alternative. Each command had a 900-second deadline; none reached it.

| Command | Exit | Wall time |
| --- | --- | --- |
| `gtimeout 900 scripts/lint.sh --fix` | 0 | 12.30 s |
| `gtimeout 900 scripts/lint.sh --fix` | 0 | 10.68 s |
| `gtimeout 900 scripts/lint.sh` | 0 | 10.96 s |
| `gtimeout 900 swift build` | 0 | 15.83 s |
| `gtimeout 900 swift build --build-tests` | 0 | 6.45 s |
| `gtimeout 900 swift test --skip-build` | 0 | 22.37 s |

Both formatter passes changed zero files. Between passes, the executor inspected the diff and
compared SHA-256 hashes for 1,037 maintained Swift files, including `Package.swift`; no hash changed.
The diff SHA-256 remained
`8b2a1597adb87b9ba0353c333ffc9629f4a1a7707dc99d211d42439b7da34810`.
The unrelated, unstaged architecture formatting retained SHA-256
`6f220965356edac9f623f39f6077863316e88c6c52b6533708e8504590434f2f`.

Each lint invocation reported `lint: ok`, zero errors and the same 32 advisory warnings as the
reviewed final-fix checkpoint. This is a passing ordinary lint gate, with disclosed advisories.
The build logs contain no compiler warnings or errors. SwiftPM reported `Build complete!` after
3.36 seconds for the product build and 4.65 seconds for the test build; wall times above include
command startup and planning. No lint configuration, pins or exceptions changed, so
`scripts/test-lint.sh` was not applicable.

The unfiltered full-suite invocation produced these complete Swift Testing pass summaries:

| Test product | Reported tests | Reported suites | Summary duration |
| --- | --- | --- | --- |
| ClawdCompositionTests | 113 | 30 | 0.676 s |
| ClawWorkspaceTests | 43 | 4 | 0.028 s |
| ClawToolsTests | 194 | 20 | 0.540 s |
| ClawTelegramTests | 68 | 15 | 0.005 s |
| ClawSubprocessTests | 14 | 2 | 0.080 s |
| ClawSecretsTests | 152 | 13 | 0.123 s |
| ClawMCPTests | 111 | 9 | 0.369 s |
| ClawLLMTests | 281 | 25 | 1.474 s |
| ClawHTTPTests | 38 | 6 | 0.142 s |
| ClawGatewayTests | 756 | 107 | 1.674 s |
| ClawExecTests | 53 | 8 | 0.021 s |
| ClawDataTests | 564 | 76 | 2.982 s |
| ClawCoreTests | 604 | 89 | 0.324 s |
| ClawCoderTests | 35 | 5 | 10.374 s |
| ClawAuthTests | 249 | 22 | 0.068 s |
| ClawAppleSpeechTests | 9 | 4 | 0.071 s |
| ClawAgentTests | 235 | 26 | 0.080 s |
| **Total** | **3,519** | **461** | |

These totals reproduce the runner's summary counts, including its skipped declarations; they do
not claim 3,519 executed cases. All 17 products reported a passing summary, with zero failures.
The existing `ContainerBackendRealAcceptanceTests` suite and its nine tests stayed skipped because
`CLAW_REAL_SANDBOX_TESTS` was absent. `AppleSpeechTranscriberLiveTests` and its two tests stayed
skipped because `CLAW_SPEECH_LIVE_TESTS` was absent. The executor enabled no live opt-ins and
sourced no owner environment. No sandbox or Coder release behavior changed in this feature.
The Coder product passed in the full run; no constrained-host split or retry was needed.
See [local verification guidance](../LOCAL_DEV.md) and [testing conventions](../TESTING.md).

## Review and offline config evidence

Separate final code/quality and test-value/redundancy reviews identified one production delivery
omission and five coverage, claim or fixture-noise items. The combined fix put both direct budget
notice sends under the shared delivery exclusion, added composed secret-boundary protection,
strengthened summary-alias and transient tool-state observations, narrowed the repeated-close
claim, and silenced the two waiter fault fixtures. The scoped independent re-review approved all
six dispositions and found no new Critical, Important or Minor finding. It accepted the existing
cohesive length and complexity advisories. The fresh full gate above followed that re-review.

The repeated-close evidence proves first-close joining, later idempotence and rejection of late
publication. It does not prove deterministic overlapping entry by a second close caller.

The executor inspected Task 8's offline probe script and complete output without rerunning it.
Each probe used `./.build/debug/clawd doctor --check-config --json`, a fresh disposable state root,
an explicit clean environment, synthetic model settings and a 30-second subprocess deadline.
The Task 8 script completed with exit 0 and reported removal of the disposable roots:

| `CLAW_TELEGRAM_PROGRESS` input | CLI exit | Observed config result |
| --- | --- | --- |
| absent | 11 | `OK` |
| `true` | 11 | `OK` |
| `false` | 11 | `OK` |
| `maybe` | 10 | `invalidBool` naming `CLAW_TELEGRAM_PROGRESS` |

Exit 11 in the valid cases reports the missing Telegram token. These are prior isolated config
results, not backend, Telegram or visual acceptance. The executor retained detailed gate logs
and review records in the local plan workspace; this document does not depend on ignored artifacts
resolving in GitHub.

## Controller rulings and their costs

- **Task 6:** place the real owner/reducer AgentRuntimeProgressTests and ToolDispatchProgressTests
  in `Tests/ClawGatewayTests/Progress`. AgentTests and ToolsTests lack the required Gateway/Telegram
  dependencies, while GatewayTests already has them; the approved design forbids dependency
  changes. Keep the named scenarios without weaker duplicate layer tests. If this placement proves
  wrong, the cost is relocating tests and test-only support; production behavior is unchanged.
- **Task 7:** test initial-registration cancellation through the real router, GRDB pickup,
  SessionLaneRegistry and TurnPresentationRegistry with a controlled admission-boundary dispatch
  fixture. Avoid adding a production async hook solely to freeze TurnRunner's private actor hop
  or blocking a cooperative thread. This proves cancelled-lane rejection and late-draft prevention.
  It does not observe that exact private hop. If deeper scheduling coverage is required later,
  the cost is adding that test coverage; production behavior is unchanged.

Both independent reviews accepted these rulings with their stated limits.

## Live acceptance still pending

The owner deferred the following required checks. This run produced no feature recordings or
live observations:

1. Establish the authorized test bot/chat, disposable test configuration and state root, candidate
   binary, Telegram client/version/window size, provider route and safe prompts. Avoid concurrent
   long-polling daemons for the same bot.
2. Make one bounded, summary-enabled request through the composed private ChatGPT provider and
   continue a tool turn with a populated summary. Record backend acceptance of the option,
   explanation-item emission or valid absence, and successful replay. An unsupported option or
   malformed replay requires resolution; do not silently retry with a changed request.
3. Record matched progress-off/on Telegram runs using identical short and multi-screen answers.
   Cover at least two tool steps, a tool lasting over 30 seconds, approval/resume, denial, `/stop`,
   provider failure and a queued second request. Show the thinking frame, early second update,
   changing steps, collapsed summary and permanent answer replacement. Include the real
   daemon/gateway/outbox path after any deterministic replay, and designated group/topic typing
   if a test group is available.
4. Inspect the recordings frame by frame. Measure time to first visible progress, stale gaps,
   stable-text displacement at collapse and final replacement, duplicate bubbles, overlap,
   scrolling and final history. Compare with the prior study's observed draft-to-final rewrap.
   Any additional disruptive jump requires a layout/pacing change and another recording. A client
   limitation requires evidence and the owner's acceptance; a second mobile client that is
   unavailable remains a stated coverage limit.
5. Add the actual outcomes and recording links, verify the documentation, and finish the branch
   only after the remaining acceptance gates. The branch and local workspace remain available
   for the owner's return.

The [2026-09-30 latency study](telegram-streaming-latency-2026-09-30.md) records prior baseline
behavior. It does not establish this feature's animation, layout, freshness, collapse, replacement
or composed backend acceptance.
