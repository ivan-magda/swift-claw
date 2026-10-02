# Telegram turn progress: automated and partial live acceptance

Date: 2026-10-01. Issue: 239. Reviewed code commit:
`e108fe5e59d69dfe7db3f2e38b57ce4a2af5dde7` on `feature/239-telegram-turn-progress`.

The initial automated gate passed after the reviewed code edit. The owner resumed live acceptance
on 2026-10-02, inline. The recordings exposed a markup defect and an ambiguous page-label design;
the follow-up below records those findings. Feature acceptance remains incomplete.

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
Those probes used revision `e63402de7cf5f9f4dd81789ca699cb57213dd68a`.
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

## Remaining live acceptance

The original live checklist follows. Setup and composed-provider evidence now exist, as recorded
below; the controlled off/on comparison and remaining lifecycle scenarios are still outstanding:

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
   scrolling and final history. Verify that permanent final answers and history contain no
   progress transcript. Compare with the prior study's observed draft-to-final rewrap.
   Any additional disruptive jump requires a layout/pacing change and another recording. A client
   limitation requires evidence and the owner's acceptance; a second mobile client that is
   unavailable remains a stated coverage limit.
5. Add the actual outcomes and recording links, verify the documentation, and finish the branch
   only after the remaining acceptance gates. The branch and local workspace remain available
   for the owner's return.

The [2026-09-30 latency study](telegram-streaming-latency-2026-09-30.md) records prior baseline
behavior. It does not establish this feature's animation, layout, freshness, collapse, replacement
or composed backend acceptance.

## Live follow-up: 2026-10-02

The owner authorized the existing bot's personal chat and the local artifact directory
`~/Downloads/telegram-turn-progress-2026-10-01/`. Tests used Telegram for macOS 12.10
(build 282985), macOS 26.6.2, the debug `clawd` candidate and the configured
`openai-chatgpt/gpt-6-sol` route. The existing personal service was stopped before testing;
one foreground candidate held the normal owner state lock. The separate group deployment was
not used. Recordings are local, cropped to the test chat at 906 × 2048 pixels and 60 fps.

| Scenario | Actual observation | Recording |
| --- | --- | --- |
| E2E-01, short answer | Run 291 completed in 5,201 ms. Temporary Working status was visible; the permanent 169-character answer contained no progress. | `2026-10-02-live-on-short.mkv` |
| E2E-02, tools and long answer | Run 292 made three fetch calls over four provider rounds and completed in 39,530 ms. The 4,863-character permanent answer contained no progress. Tool rows exposed literal Markdown escapes; this was a failure, not accepted rendering. | `2026-10-02-live-on-tools-long.mkv` |
| E2E-04, markup fix | Run 294 made three fetch calls over four rounds and completed in 43,285 ms. The client displayed a proper bullet list and domains without backslashes. The 5,265-character permanent answer contained no progress. | `2026-10-02-live-markup-fix.mkv` |
| E2E-05, second request | Submitted through the client while run 294 was active; the client displayed its pending-send clock. Gateway admission occurred after run 294 completed, followed by an 18-character final answer. This does not prove simultaneous gateway admission or the lane race. | Same recording as E2E-04 |

The composed ChatGPT route accepted summary-enabled requests. Read-only inspection of the test
runs' stored replay metadata found a nonempty summary on run 292's first tool proposal (25
characters), followed by successful tool continuation. Run 294 likewise retained nonempty
summaries (27 and 34 characters) and completed later provider rounds. Only counts and lengths
were recorded; no credentials or replay payloads were exported. Optional summary text was not
visible in the sampled E2E-04 frames, so that recording alone does not prove the HTML bold display.

The markup defect was a missing blank line after the raw `<tg-thinking>` HTML block. Telegram
therefore treated the subsequent list and its escapes as literal text. The fix terminates that
block before the Markdown rows. The owner also selected generated HTML bold for outer `**`
explanation headings; the renderer escapes the body and closes the tags even for an incomplete
streamed heading. The [Telegram Rich Markdown rules](https://core.telegram.org/bots/api#rich-markdown-style)
explain the distinction between Markdown and text inside HTML blocks.

E2E-04 also exposed the approved host-only preview's ambiguity: the actual requests were
`www.swift.org/documentation/`, `www.swift.org/getting-started/` and
`swift.org/documentation/`. The owner approved showing host plus path, omitting user information,
query and fragment, with middle elision for long paths. That updated rule is recorded in the
architecture and the local accepted design.

The earlier recordings whose names contain `approval-queue` or `approval-resume` are setup
attempts, not acceptance evidence. Later approval runs are recorded below. Sandbox health reported an existing image-pull failure and `admitting=false`; its
guards were not bypassed. A tool execution over 30 seconds, approval/resume, denial, stop, provider
failure, matched off/on short and multi-screen answers, and quantitative transition comparison
remain to be completed. No authorized group/topic or second mobile client has been exercised.


### Continued live checks

- E2E-06-URL (run 296): two fetch calls, 7,251 ms, final `Пути страниц проверены.`
  without progress. Recording: `2026-10-02-live-url-and-approval.mkv`. The first path was partly
  visible before completion; this short run did not visually establish both complete labels.
- E2E-07 (run 297): two fetches followed by a gated write of one disposable fixture. The owner
  pressed Approve after 98 seconds; the expected fixture content was verified on disk. The
  continuation completed in 9,771 ms with `Подтверждение проверено.` and no final progress.
  The continuation also repeated both fetches; this is an observed behavior requiring triage,
  not evidence of an extra file write. Recording: `2026-10-02-live-approval-07.mkv`.
- E2E-08 (run 298): intended denial, but the owner confirmed pressing Approve. The durable row
  is APPROVED and the fixture exists. Count this as a second approval run, not denial coverage.
  The bot correctly reported that no denial occurred. Recording: `2026-10-02-live-denial-stop.mkv`.

The approval wait exposed another visual problem: between elapsed labels 14s and 79s the first
unchanged completed tool row was still being revealed a few characters at a time. The second row
only began appearing around 84s. The contact sheet `live-approval-wait-detail.png` shows this
sequence. The timer continued updating, so this is not a claim of stopped server activity.
The cause is still under investigation; visual acceptance remains open.

The full local gate after the markup and URL edits passed: two formatter runs (the second fixed
zero files), `scripts/lint.sh`, `swift build`, and bounded unfiltered `swift test`. The test logs
report 3,522 tests across 461 suites and 17 products, with the same 11 existing opt-in skips.
Evidence is in the local `live-url-lint*`, `live-url-build.log`, and `live-url-tests.log` files.

- E2E-08b (run 299): the owner pressed Deny after 8 seconds. Durable state REJECTED,
  no fixture file, buttons removed, and permanent notice `Understood — I won't run that action.`
  with no progress. This is the actual denial coverage in `2026-10-02-live-denial-stop.mkv`.
- E2E-09 (run 300): `/stop` submitted at 06:23:46.275 UTC during generation stayed visibly
  pending in the client. The run completed after 61,296 ms (13,907 characters); the command
  subsequently produced `Nothing to stop.`. This does not pass active cancellation acceptance.
  Recording: `2026-10-02-live-stop-09.mkv`.
- E2E-10 (run 301): another intended stop test, but the owner confirmed pressing Deny first.
  State REJECTED after 22 seconds, fixture absent; the later `/stop` correctly found no work.
  Recording: `2026-10-02-live-stop-approval-10.mkv`. Do not count this as active cancellation.


### Isolated rendering diagnosis

With the candidate daemon stopped, a gated scratch test used the normal sealed-secret loader,
verified the configured bot identity, and sent only to the single approved personal owner chat.
No additional poller or provider request ran. The fixture drove the real TurnProgressState and
TelegramProgressRenderer, then the real TelegramClient. This diagnoses rendering; it is not a
substitute for the daemon/gateway/outbox acceptance scenarios.

1. Dynamic versus fixed elapsed label: 17 draft sends each, an early second send, then the same
   approximately 1.25-second spacing. Both variants revealed ordinary tool rows very slowly.
   The fixed timer did not resolve the symptom. Recording:
   `2026-10-02-live-timer-diagnostic-swift.mkv`, sheet `live-timer-comparison.png`.
2. Two candidate presentations, 10 sends each: per-row thinking blocks displayed both complete
   page paths immediately in the sampled frames. They use Telegram's gray progress style.
   Changing draft IDs with the original renderer did not yield usable complete rows during
   this short run. Recording: `2026-10-02-live-rendering-variants.mkv`, screenshot
   `live-thinking-rows.png`. These isolated experiments preceded the product change described below.

The scratch test passed both live runs (54.223 s and 34.484 s), was archived outside tracked
sources, and removed from the test target. The earlier Python attempt lacked the sealed bot
credential and sent no message; `2026-10-02-live-timer-diagnostic.mkv` is unused setup.
Disposable files created in E2E-07/08 were content-checked and moved to the approved artifact
folder's `fixtures/` directory. All captures are closed and the personal candidate is stopped.
The group deployment was left untouched.

The owner requested a visible comparison after reporting that the asynchronous preference prompt
was not visible. A side-by-side still (`progress-visual-comparison.png`) and 12-second video
(`progress-animation-comparison.mp4`) show the observed difference. Both variants were repeated
in Telegram with explicit Russian labels in `2026-10-02-live-visual-repeat.mkv`; the source is
archived locally and the temporary test removed. The owner selected variant 2, the gray-row
style. The renderer now emits each tool row and earlier-step count as a separate complete
thinking block, with HTML escaping. The same draft ID, elapsed timer, cadence and collapse
behavior are retained. Permanent answers still exclude progress.

The renderer regression tests first failed on the ordinary-row implementation (five tests, nine
expected issues), then all five passed after the change. The fresh full gate also passed:
`scripts/lint.sh --fix`, an unchanged second fix, `scripts/lint.sh`, `swift build`, and
`gtimeout 900 swift test`. The 17 products reported 3,522 tests in 461 suites; 11 existing opt-in
tests were skipped. No compiler warnings were emitted; lint retains the existing advisories.
Local evidence: `live-thinking-rows-red.log`, `live-thinking-rows-green.log`, and
`live-thinking-{lint,build,tests}.log`. This automated gate does not close the remaining visual
and lifecycle acceptance criteria.

### Gray-row candidate through the real daemon

- E2E-11 (run 303): two fetches, 23,674 ms, 1,728-character final answer, message 948.
  `2026-10-02-live-thinking-product.mkv` shows both full paths as gray completed rows;
  they collapse when answer text begins. Stored assistant content contains no thinking tag or
  progress heading. First Working is visible by video 28.0 s; the submitted prompt first appears
  at 27.0 s (0.5-second sampling, approximately one second to visible progress). The first complete
  row is visible at 35 s, both at 40 s. Timer labels at 40/41/42 s are 11/13/14 s, with no movement
  of the stable rows in those frames. This run resolves the minute-long ordinary-row reveal.
- Collapse still moves the preceding user-name anchor down: Vision OCR on the original
  906 × 800 bottom crops measures y=67.7 at video 43 s and y=198.9 at 44 s, a **131.2 px**
  displacement. This is a measured layout effect, not an accepted no-jump result.
  `thinking-collapse-detail.png` shows the before/after. The bottom 800 pixels are mostly empty
  around 51–52 s during final replacement, then final text appears; that crop alone does not prove
  the entire chat was blank. Final replacement acceptance remains open.
- E2E-12 (run 304): `/stop` submitted during the real run again remained pending in Telegram.
  The run finished after 56,738 ms with 9,169 characters; only afterwards did the bot respond
  `Nothing to stop.`. `2026-10-02-live-thinking-stop.mkv` records this failed active-stop scenario.
  The row-style fix does not resolve command delivery. Bot API 10.3 exposes a separate
  [draft stop-button update](https://core.telegram.org/bots/api#sendrichmessagedraft); that API is
  not wired by this feature, and its effect on this client symptom has not been established.
- Matched short runs 305/307 (on/off) each produced the same 43-character answer (1,855/1,918 ms).
  Matched long runs 306/308 each made two fetches and produced byte-identical 4,210-character
  answers: 18 identical paragraphs (25,570/24,539 ms). Scoped read-only history comparison found
  no progress text in either pair. Recordings: `2026-10-02-live-matched-on.mkv` and
  `2026-10-02-live-matched-off.mkv`; comparison clip `matched-short-on-left-off-right.mp4`.
  The sampled short frames show replacement followed by text reveal in both modes, without
  duplicate answers. Long-answer contact sheets show auto-scrolling in both modes; a complete
  quantitative final-transition comparison is still outstanding.
- E2E-13 (run 309): a separate temporary process selected a deliberately nonexistent model on
  the same ChatGPT route, with fallback disabled. The provider returned HTTP 400; the run degraded
  as `providerUnavailable` after 574 ms, durable state FAILED, and the outbox delivered message 962.
  `2026-10-02-live-provider-failure.mkv` records the permanent error replacing the temporary
  presentation. No credential or saved configuration was changed.

All captures are closed and temporary personal processes stopped. The saved normal configuration
is unchanged, and the separate group deployment was untouched. The remaining acceptance includes
active `/stop`, a tool execution lasting over 30 seconds (approval waits do not count), gateway
admission of a second request while the first is active, and owner review/resolution of the measured
collapse and final replacement behavior. The configured sandbox still has its pre-existing image
pull failure; no guard was bypassed. Group/topic and mobile-client coverage remain unavailable.
