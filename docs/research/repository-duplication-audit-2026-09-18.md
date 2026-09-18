# Repository duplication audit — 2026-09-18

This is a point-in-time refactoring record, not a new normative contract. The work preserves
observable behavior, serialized data and the target dependency graph. The only architecture edit
records ownership of the existing learning-operation identity rule in `ClawCore`.

## Method and scope

1. Surveyed within every source target, its tests and resources: Core, Agent, Gateway, Data, LLM,
   Auth, Secrets, HTTP, Telegram, Tools, MCP, Coder, Exec, Subprocess, AppleSpeech, Workspace, clawd
   and TestSupport. Also checked package/build tooling, scripts, CI/release/deploy files and guides.
2. Compared rules across targets and layers: validation, serialization, errors/retries, paths,
   configuration, request/process/resource ownership and test mechanics. For each candidate,
   compared accepted inputs, outputs, side effects, ordering and error handling; searched existing
   owners and checked dependency direction before extracting anything.

`rg` semantic searches were supplemented by an eight-significant-line duplicate-window scan of
996 tracked Swift/shell/YAML files. The scan was a candidate generator, not evidence that similar
code has the same meaning. Dependencies, generated builds and external research code were not
refactoring targets. Repeated public documentation and historical migration inputs were evaluated
as contracts/evidence, not mechanically collapsed.

## Confirmed consolidations

| Group | Shared owner and former users | Preserved semantics and dependency decision |
| --- | --- | --- |
| History exchanges | `HistoryHygiene.groups`; sanitation and ContextBuilder's second grouping pass | Drops orphan/incomplete exchanges together, retains extra observations and sanitized-row group IDs. Rendering and trust attribution stay in ContextBuilder. Agent only. |
| Learning inference | `LearningOperationRunner+Inference`; evaluator and reflector | Same tool-free request, safe route switch, primary cooldown and final-route usage. Different output caps are explicit values; carrier, authorization and result admission remain phase-specific. Gateway only. |
| Learning operation identity | Core `LearningOperationKey.evaluation/reflection`; Gateway runner plus Data authorization, reflection discovery and trial lineage | One phase/source/prompt/schema/rubric recipe; same digest bytes. Authorization still uses the operation's job/epoch and checks trigger equality separately. Existing Core dependency in both layers. |
| Feedback event persistence | `ScheduledLearningStoreGRDB+FeedbackEvents`; taps and free-text challenges | Same revision CAS, predecessor lookup, owner actor, insert and run association. Payload/update ID remain actual optional event fields. Admission, consumption, audit and transactions stay separate. Data only. |
| Live trial selection | Existing `+TrialRows`; fire binding and owner view | Same SQL selection/order. Runtime corruption still throws StoreError; owner view still reports unreadable through its own policy. Data only. |
| SQLite value/placeholder mechanics | Existing `SQLiteStoredValue` and GRDB `databaseQuestionMarks`; replay state and four SQL builders | Missing/wrong storage classes still become nil; replay byte bound unchanged; same placeholders. No new helper or dependency. |
| Loaded runtime secrets | Internal validating `Secrets` initializer in ClawSecrets; env and encrypted loaders | Required nonempty Telegram token, exactly-empty optional keys become nil, whitespace bytes preserved. Env warning remains after successful validation. Core value initializer unchanged. |
| ChatGPT diagnostics | Existing Auth `ChatGPTProviderMetadata.safeDiagnostic`; Auth login and LLM Responses | Same sanitize/redact order and diagnostic byte cap, with original secret sets. Package visibility uses existing LLM→Auth dependency. |
| Login failure mapping | One catch chain in `AuthLoginWorkflow`; device authorization and token exchange | Same cancellation, typed OAuth and unexpected-error outcomes; same sequence and persistence boundary. No abstraction added. |
| HTTP success classification | Existing Core `HTTPResponseBodyPolicy.isSuccess`; three LLM checks | Same 200..<300 predicate as Auth/transport; provider error and retry policies remain separate. |
| MCP request ownership | Private `MCPServerSession.response`; listing and tool invocation | Same request ID tracking, budget race and successful clear; discovery/call timeout errors remain distinct. No new dependency. |
| Exact secret redaction | Existing Core `SecretRedactor`; ExfilArgGuard audit rendering | Same ordered replacements and token; exfil detection and shaped-secret passes remain separate. |
| Tool vocabulary | Existing Core enums; MemoryWriteTool schema/description and ExecuteCodeTool language schema | Same order, labels, defaults and rendered strings. Advertised values now name the domain declarations already used by validation. |
| Inventory failure downgrade | `RepositoryInventory.captureIfAvailable`; preparation and final inspection | Only unavailable inventory, Git command failure and invalid Git output become unknown evidence. Cancellation, deadline and supervision failures still propagate. Coder only. |
| Container engine status | Existing `ContainerBackend.engineRunning`; probe and post-execution check | Same successful bounded JSON status interpretation. Explicit existing 15-second/5-second limits preserved. Exec only. |
| CLI env-file location | Existing `EnvironmentLoader`; Coder setup and secret seal | Explicit path, then CLAW_ENV_FILE, then home default; even explicitly empty paths keep precedence. clawd only. |
| Probe resource ownership | Existing `MCPProbe.run`; doctor and MCP CLI | Same protected-egress client, quiet logger, session disconnection and awaited best-effort client shutdown. clawd only. |
| CLI credential errors | Existing `openingTokenStore`; MCP reads and locked writes | Same typed error/exit mapping; mutation lock still spans the operation. clawd only. |
| Health collection | Existing `DoctorHealth`; CLI doctor and live reporter | Same general/scheduler/approval reads and row order. Live versus unobservable route health stays explicit. clawd only. |
| Test mechanics | ClawTestSupport credential load double and learning-view inspection; MCP transport and Exec fixtures | Identical fixture behavior shared at the smallest existing support layer. Fixed fresh credentials stay in composition fixtures; SDK transport stays in MCP tests. Identical learning inference budget/route fixtures stay in Gateway test support; the group-policy workspace fixture reuses makeTemporaryRoot. No scenario flags or new dependencies. |

## Important similarities deliberately kept separate

- **Retries and failures:** OAuth Retry-After accepts positive ASCII integers; Responses accepts
  nonnegative trimmed integers; compatible HTTP supports fractional seconds and milliseconds.
  Credential refresh cooldown and inference jittered backoff have different ownership/deadlines.
  Telegram flood control comes from its API envelope. Possibly-sent ChatCompletions and Responses
  failures expose different typed outcomes. Existing `RetryBackoff`, `RouteSwitch` and
  `ProviderUsageAccountant` already share the common portions.
- **Turn versus learning orchestration:** deadlines, budget gates, fallback notices and durable
  accounting commits differ. A completed streaming response can win a deadline; buffered late
  completion preserves authoritative usage but reports timeout. Unknown learning cancellation
  remains conservative. No generic retry/deadline framework was introduced.
- **Wire parsing and canonicalization:** historical migrations describe different schemas. JSON
  string encoding, digest encoding with a trailing newline and slash-escaping policy are not
  interchangeable. MCP schema redaction sorts keys before collisions; Coder redaction does not.
  Buffered ChatCompletions accepts present empty tool IDs/names while SSE drops them and Responses
  rejects malformed calls. The intent of the buffered/SSE discrepancy could not be established
  (one comment claims equivalence); it was not silently changed by a DRY refactor.
- **Filesystem and process policy:** workspace creation does not retighten an existing directory,
  while PrivateDirectory does. Secret envelopes, Coder reports and inventory have different size,
  symlink, mode, rollback and cancellation rules. Coder's durable receipts/verified descendant
  cleanup differ from Subprocess capture. Output overflow may drain-and-reject, abort, or truncate.
  Staged basename checks use different Unicode casing/normalization; equivalence was not assumed.
- **Configuration and presentation:** strict MCP YAML differs from tolerant skill metadata.
  Env secret scrubbing preserves bytes, while Coder setup parses literals and checks concurrent
  modification. Setup filters unsuitable PATH components; config validation rejects them.
  User-Agent has a different byte cap from diagnostics. Label sanitizers have different control,
  separator, redaction and fallback policies. GitHub request parsing differs from verification
  against a frozen publication repository.
- **Resources and delivery:** image handling keeps bounded bytes in memory; voice owns a private
  scratch file and transcription deadline. Approval callbacks and learning feedback differ in
  admission/CAS/audit despite sharing ReplySender. HTTP body total caps and stream unread caps
  enforce different resource contracts.
- **Tests and infrastructure:** recorded URL-keyed HTTP fixtures, queued streaming fixtures and
  repeat-last OAuth fixtures are different doubles. Load-scripted credential storage is distinct
  from write-failure recording. Learning callback harnesses have different clocks/router/audit
  behavior. launchd/systemd lifecycle and CI/release platform build/checksum steps remain explicit.
  Cancellation-ignoring, non-latching and multi-waiter gates are not interchangeable. Self-contained public guides retain the instructions each reader needs; no guide behavior changed.

## Test intent and redundancy review

| Risk | Production seam | Nearest existing coverage | Unique reachable mutant | Primary new test |
| --- | --- | --- | --- | --- |
| Possibly-started learning failure retries or loses observed usage | Learning dispatch, failed-call accounting, real SQLite commit | Existing safe-failover and successful billed-row tests | Unwrap a possibly-started quota cause and retry, or discard its observed token lower bound | `OperationRunnerTests.aPossiblyStartedFailureCannotSwitchAndKeepsItsObservedUsage` |
| Proven no-start failure becomes estimated spend or loses its usage row | Failed-call .notStarted branch and real SQLite commit | Successful billed-row tests do not enter this branch | Charge conservative usage or omit the confirmed-zero row | `OperationRunnerTests.aProvenNoStartFailureClosesWithConfirmedZeroUsage` |
| Encrypted loader skips empty-key normalization or changes credential bytes | Public encrypted seal/load path | Existing nonempty round trip; env blank-key test is another entry point | Use raw Secrets construction or trim whitespace | `EncryptedFileSecretStoreTests.sealNormalizesEmptyAPIKeysWithoutTrimmingCredentialBytes` |

An independent test-only review approved these three cases and the fixture moves. Existing Core,
Data and Gateway key tests retain independently assembled keys as compatibility checks instead of
being rewritten to mirror the new constructors. No duplicate reflector variants were added.
`finalPresenceFailureOverridesGuestOrCancellationResult` was removed because the existing
`failedCleanupDisarmsAdmissionUntilNextPrepare` has the same fixture and assertions plus admission
checks, killing the same cleanup-outcome mutant. That deletion received a separate independent
review. The root review checked the shared fixture moves against their original implementations.

## Repeat search and verification

Every former call site was re-read after extraction. Repeated semantic searches verify one owner
for current learning key recipes, feedback insertion/revision SQL, live-trial SQL, secret normalization,
ChatGPT diagnostic cap, MCP track/clear, inventory error downgrade, engine status interpretation and
CLI path/probe/health rules. Old credential/view/MCP fixture declarations are gone. Repeated
normalized-window scans left historical migrations, forwarding signatures, distinct policy branches
and required guards around suspension points; these were reviewed rather than counted as defects.

Final local validation on macOS arm64 with Swift 6.3.3:

- `scripts/lint.sh --fix`: layout fixes in four files, reviewed before check mode.
- `scripts/lint.sh`: `lint: ok`; 47 advisory warnings, no errors.
- `swift build`: `Build complete! (8.63s)`.
- `swift test`: 3436 tests in 439 suites passed (15.129 seconds test execution).
- Earlier affected-target test run: 2685 tests in 325 suites passed.
- `git diff --check`: clean.

Opt-in real container and live speech suites were not enabled. Linux portability is left to the
repository CI; local validation is not evidence of a Linux run.
