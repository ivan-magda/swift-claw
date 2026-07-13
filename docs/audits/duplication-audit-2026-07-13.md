# Duplication audit — swift-claw

**Date:** 2026-07-13 · **Snapshot, not a living document.** This is a point-in-time DRY audit; it is not normative and is not maintained. Once the findings are actioned (or consciously declined), it stops reflecting the tree. Treat it as the backlog it was on the date above.

**Scope:** 195 tracked source files + 200 test files (`Sources/**` and `Tests/**`, excluding one test file whose structural map failed to generate).

**Method:** produced by a multi-agent workflow — a Haiku agent mapped each file's declarations/constants/magic-literals/patterns into a structured index; seven Opus category hunters (util-helpers, logic-patterns, constants-literals, types-models, protocol-conformance, test doubles, test helpers/fixtures) swept the sliced indexes for cross-file duplication; every candidate was then re-read against the real code by an adversarial Opus verifier instructed to *refute* unless the code proved genuine duplication. 55 candidates → **46 confirmed / 9 rejected**, de-duplicated here to **33 distinct defects**. Framework-required conformances and intentional module boundaries were deliberately excluded.

**How to read the priorities:** P1/P2/P3 rank by impact-then-effort, not raw severity. Impact reflects the actual threat model (a rename that needs a data migration anyway, or drift that sits in dead/test-only code, is rated low even where the pattern looks alarming). See *Notes & limitations* at the end for what the map-based, per-category slicing could and could not see.

---

## Summary

Mapped 195 source and 200 test files, hunted 55 duplication candidates, and confirmed 46 raw findings that collapse to 33 distinct defects (the epoch codec, config parser, header lookup, canonical-JSON, SHA256-target, doctor rows, and secret redaction each surfaced under multiple hunter lenses). Every confirmed item is a second copy of a helper, constant, type, or test double that the repo's "Reuse before you add" rule classifies as a defect; three already show live drift (config trims `.whitespaces` vs `.whitespacesAndNewlines`, a doctor-Row doc comment diverged, and a scheduling-anchor comment misstates its own date). The highest-leverage work sits in ClawData store codecs, ClawTools security helpers (JSON canonicalization, SHA256 targets, secret redaction), the ClawGateway doctor-Row types, and a large cluster of copy-pasted test doubles/fixtures that promote cleanly into `ClawTestSupport`.

## Findings by impact

| Priority | Title | Sites | Effort | Impact | Shared home |
|---|---|---|---|---|---|
| P1 | Epoch-second Date column codec in two GRDB stores | 2 | low | med | `ClawData/Database` (new `EpochSecondCodec`) |
| P1 | Bounded/positive numeric-config parser reimplemented ~6× | 6 | med | med | `ClawCore/Config` (new `ConfigParse`) |
| P1 | Canonical sorted-keys JSON encoding for approval hashing | 2 | low | med | `ClawCore/Domain/Support` (`CanonicalJSON`) |
| P1 | SHA256 hex-16 canonical-target hand-rolled vs `SHA256Digest` | 3 | low | med | `ClawCore/Domain/Support/SHA256Digest` |
| P1 | Exec staging size/count caps duplicated tool↔workspace | 2 | low | med | `ClawCore/.../ExecutionContracts` (`ExecStagingLimits`) |
| P1 | Three parallel doctor-health `Row` types vs `DoctorReport.Check` | 3+5 | med | med | `DoctorReport.Check` (existing) |
| P1 | Secret redaction: copied bodies + hardcoded placeholder | 4 | med | med | `ClawCore` (move `SecretRedactor`) |
| P1 | Agent runtime test doubles copied into two support files | 6 | low | med | `ClawTestSupport` |
| P1 | Agent response/outcome builders copied byte-for-byte | 4 | low | med | `ClawTestSupport` |
| P2 | Durable message-role/provenance vocabulary as inline SQL | 6 files | med | med | `ClawCore/Persistence` enums (existing) |
| P2 | Telegram 32_768 per-message char limit duplicated | 2 | low | med | `ClawCore/Domain/Support` (`TelegramMessageLimits`) |
| P2 | Truncation marker `…[truncated]` defined twice | 2 | low | med | `ClawCore/Domain/Support` (`TextTruncation`) |
| P2 | YYYY-MM-DD / wall-clock day formatting duplicated | 3 | low | med | `ClawCore/Domain/Support/Date+UTCDay` |
| P2 | Private-data prompt-file set `{MEMORY.md,USER.md}` | 2 | low | med | `ClawCore` `WorkspaceFile` |
| P2 | HEARTBEAT_OK ack token in detector + prompt prose | 2 | low | med | `HeartbeatAck.token` (existing) |
| P2 | `ScriptedResolver` DNS double copied across two targets | 2 | low | med | `ClawTestSupport` (+ClawTools dep) |
| P2 | `ScriptedHTTP` recording double duplicated 4× | 4 | med | med | `ClawTestSupport` |
| P2 | `ProviderUsage` fixture builder copied across Run tests | 5 | low | med | `ClawDataTests/Stores/Run` support |
| P2 | `RecurrenceRule` fixture builders per scheduling suite | 5 | med | med | `ClawTestSupport` |
| P2 | Scheduling anchor timestamps as magic literals | 9 files | low | med | `ClawTestSupport` (`SchedulingTestClock`) |
| P2 | Duplicate OpenAI wire `Usage` decode struct | 2 | low | low | `ClawLLM/Provider` (`WireUsage`) |
| P2 | Case-insensitive `getHeader` on two HTTP value types | 2 | low | low | same file (`[String:String]` ext) |
| P3 | Positive-Int64 arg parser in bot command handling | 2 | low | low | `ClawCore/Domain/Bot` (`PositiveInt64`) |
| P3 | LLM run-bound defaults `EnvDefaults`↔`RunBudget.default` | 3 vals | low | low | `ClawCore/Domain/Support` (`RunDefaults`) |
| P3 | Sandbox container resource defaults across config layers | 3 vals | low | low | `AppConfig.EnvDefaults` (existing) |
| P3 | Approval-expiry default 3600 in AppConfig + TurnRunner | 2 | low | low | drop TurnRunner default / inject |
| P3 | `CLAW_*` secret env-var names outside `EnvKey` | 3 | low | low | `EnvSecretStore.EnvKey` (existing) |
| P3 | Approval `"PENDING"` hardcoded in DB index condition | 1+enum | low | low | `ApprovalState.pending.rawValue` |
| P3 | `HangingProvider` deadline-losing double per module | 2 | low | low | `ClawTestSupport` |
| P3 | `runStates(databasePath:)` query helper copied 3× | 3 | low | low | `ClawGatewayTests/Support/ApprovalTestSupport` |
| P3 | `makeStateRoot()` temp-dir factory in every secrets test | 4 | low | low | `ClawTestSupport` (+ClawSecretsTests dep) |
| P3 | Temp SQLite path helper open-coded ~6× | 6 | low | low | `ClawTestSupport` |

## Details

### Epoch-second Date column codec in two GRDB stores
- `Sources/ClawData/Stores/Approval/ApprovalStoreGRDB.swift :: static epoch(_:)/date(fromEpoch:)` (479–491, `private extension`)
- `Sources/ClawData/Stores/Scheduling/ScheduledJobStoreGRDB.swift :: static epoch(_:)/date(fromEpoch:)` (673–683, non-private extension)

Byte-identical bodies (`Int64(instant.timeIntervalSince1970.rounded())` / `value.map { Date(timeIntervalSince1970:) }`) under the same "Epoch-second column codec" MARK. These are the only two stores that hand-roll epoch↔Date; all others bind `Date` directly through GRDB. Used ~25× (Scheduling) and ~6× (Approval) for persisted timestamps compared across the run/approval/scheduler tables. Drift risk: change rounding/nil policy in one and cross-table timestamp comparisons silently disagree.

Plan: add `enum EpochSecondCodec { static func epoch(_:) -> Int64; static func date(fromEpoch:) -> Date? }` in `Sources/ClawData/Database/`, delete both extensions, mechanically rename call sites `Self.epoch`→`EpochSecondCodec.epoch`. Also removes the accidental non-private exposure of the Scheduling codec.

### Bounded/positive numeric-config parser reimplemented ~6×
- `Sources/ClawCore/Config/AppConfig.swift :: positiveBudgetDouble(_:default:)` (277–291)
- `Sources/ClawCore/Config/AppConfig.swift :: positiveBudgetInt(_:default:)` (295–306)
- `Sources/ClawCore/Config/AppConfig.swift :: positiveBudgetIntOrNil(_:)` (309–320)
- `Sources/ClawCore/Config/AppConfig.swift :: boundedInt(_:key:default:minimum:)` (343–359)
- `Sources/ClawCore/Config/AppConfig.swift :: parseApprovalExpiry(_:)` (526–541)
- `Sources/ClawCore/Config/ExecConfig.swift :: boundedExecInt(_:default:range:error:)` (236–252)

One skeleton: trim → empty-fallback → `Int/Double(trimmed)` → bound check → throw `ConfigError`. `boundedExecInt` is already the general (range + error-closure) form the others specialize. Live drift already present: AppConfig trims `.whitespaces`, ExecConfig `.whitespacesAndNewlines`, so a trailing-newline env value parses in one file and throws in the other.

Plan: add `enum ConfigParse` (`Sources/ClawCore/Config/ConfigParse.swift`, module-internal) with `boundedInt(range:onInvalid:)`, `boundedIntOrNil(...)`, and `positiveDouble(...)` on a single `.whitespacesAndNewlines` charset; re-express the five named functions as one-line wrappers carrying their distinct bound/error; delete `boundedExecInt`. `parseApprovalExpiry`'s deliberate error-case constraint is preserved via the per-call `onInvalid` factory.

### Canonical sorted-keys JSON encoding for approval hashing
- `Sources/ClawTools/Policy/ToolPolicyGate.swift :: canonicalArgs(_:)` (277–293)
- `Sources/ClawTools/Tools/ExecuteCodeTool.swift :: canonicalJSON(_:)` (465–475)

Both pin `JSONEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]` and encode-to-UTF8-string; this exact option pair exists nowhere else. Both feed `ApprovalArgsHash.sha256Hex`/`canonicalTarget`, so the format is a security boundary — a silent drift (e.g. someone adds `.prettyPrinted`) corrupts approval-hash identity.

Plan: add `CanonicalJSON.encode<Value: Encodable>(_:) -> String?` in `ClawCore/Domain/Support` (already reachable from ClawTools, hosts `SHA256Digest`); `canonicalJSON` delegates; rewrite `canonicalArgs` as `JSONValue.parse(raw).flatMap(CanonicalJSON.encode) ?? raw`. Do NOT fold in `ScheduledJob.encodedJSON`/`PolicyFingerprint`/`DoctorReport` — they use different `outputFormatting` and share no byte format; changing them would alter persisted/fingerprint bytes.

### SHA256 hex-16 canonical-target hand-rolled vs SHA256Digest
- `Sources/ClawCore/Domain/Memory/MemoryWriteArguments.swift :: canonicalTarget(for:)` (77–81) — inline `SHA256.hash(...).prefix(8).map { %02x }.joined()`
- `Sources/ClawTools/Tools/ExecuteCodeTool.swift :: canonicalTarget(language:canonicalArgsJSON:)` (477–480) — correct `SHA256Digest.hex(...).prefix(16)`
- `Sources/ClawCore/Domain/Policy/PolicyFingerprint.swift :: hash(parts:)` (24–26) — same `%02x` digest→hex tail, distinct streaming construction
- Home: `Sources/ClawCore/Domain/Support/SHA256Digest.swift :: hex` (5–13)

Both approval targets share `<prefix>:<field>:<first-16-hex-of-sha256(utf8)>`; `first-8-bytes-hexed` is bit-identical to `first-16-hex-chars`. `MemoryWriteArguments` re-implements the digest call and the `%02x` loop that `SHA256Digest.hex` already owns — the `%02x` idiom is now in three places. Drift risk: a hex casing/format change wouldn't propagate to the hand-rolled copy, breaking approval-target identity.

Plan: replace `MemoryWriteArguments` lines 78–79 with `String(SHA256Digest.hex(request.item.text).prefix(16))` and drop the now-unused `import Crypto`. Add `SHA256Digest.hex(_ digest:)` (or `hex(over: some Sequence<UInt8>)`) and refactor `hex(_ data:)` through it, so `PolicyFingerprint.hash` can end with `SHA256Digest.hex(hasher.finalize())` while keeping its streaming length-prefixed updates.

### Exec staging size/count caps duplicated tool↔workspace
- `Sources/ClawTools/Tools/ExecuteCodeTool.swift :: maxCodeBytes/maxStagedFileBytes/maxStagedTotalBytes/maxStagedFiles` (19–22, enforced 89,94,150,302,427,556,562,604)
- `Sources/ClawExec/Workspace/ScratchWorkspace.swift :: maxEntrypointBytes/maxInputBytes/maxInputTotalBytes/maxInputFiles` (19–22, enforced in `validate()` 98,103,124,129)

Same four values, order, and semantics (16 KiB / 1 MiB / 4 MiB / 16) — one contract enforced at two trust boundaries. Drift risk: bump one and the peer silently rejects/accepts at exactly the boundary, a confusing partial failure. Values are also re-typed in refusal prose (ExecuteCodeTool 90,95) and `ToolApproval.swift:34`.

Plan: add `public struct ExecStagingLimits: Sendable, Equatable` with `static let default` to `ClawCore/Domain/Execution/ExecutionContracts.swift` (both modules depend on ClawCore); both sites read from it, keeping both guard layers. Interpolate the values into the refusal strings so prose can't drift.

### Three parallel doctor-health Row types vs DoctorReport.Check
- `Sources/ClawGateway/Response/ApprovalsHealth.swift :: ApprovalsHealthRows.Row` (10–20)
- `Sources/ClawGateway/Response/SchedulerHealth.swift :: SchedulerHealth.Row` (8–18) — byte-identical to the above
- `Sources/ClawGateway/Response/SandboxHealthRows.swift :: SandboxHealthRows.Row` (31–41) — same shape, `ok:Bool` instead of `headline:Bool`
- Superset target: `Sources/ClawGateway/Response/DoctorReport.swift :: DoctorReport.Check` (34–54)
- Conversions: `DoctorHealth.swift` 79–87/98–109/122–124, `DoctorCommand.swift` 43–44/69–70, `DaemonBuilder+Doctor.swift` 36–42

Two identical structs plus a third near-identical, all mechanically mapped to `Check` at 5+ sites. `HealthRowsBuilder` (48–137) already emits `[DoctorReport.Check]` directly in-module, proving the intermediate `Row` layer is redundant; the `ok`/`headline` split folds into `Check`, which carries both. The Gateway `EmptyWorkspace`… no — here the drift is the diverging headline-vs-ok semantics per subsystem.

Plan (adopt HealthRowsBuilder's pattern, do NOT add a fourth `HealthRow`): have `SchedulerHealth.rows`, `ApprovalsHealthRows.rows`, `SandboxHealthRows.rows`/`admittingRow` return `[DoctorReport.Check]` with `group`/`ok`/`isHeadline` set inline; delete the three `Row` structs; collapse the converter closures/loops into `report.add(contentsOf:)`. Retarget the three test helpers from `[…Row]` (`.headline`→`.isHeadline`).

### Secret redaction: copied bodies + hardcoded placeholder
- `Sources/ClawLLM/Provider/OpenAICompatibleProvider.swift :: sanitize(message:)` (314–319) — token `<redacted-key>`
- `Sources/ClawTelegram/Client/TelegramClient.swift :: sanitize(_:)` (202–208) — token `<redacted-token>`
- `Sources/ClawTools/Search/ExaSearchProvider.swift :: redact(_:)` (98–103) — token `[REDACTED:secret-value]`
- `Sources/ClawTools/Policy/ExfilArgGuard.swift :: renderRedacted(argsJSON:)` (175) — 4th inline copy, same literal
- Canonical home: `Sources/ClawTools/Text/SecretRedactor.swift :: SecretRedactor / .replacement` (6)

Every site is the same guarded `input.replacingOccurrences(of: secret, with: <token>)`; `SecretRedactor` already generalizes this and owns the canonical token, and its doc comment asserts the arg-guard coupling in prose rather than code. The three transport placeholders have already drifted three ways — the visible symptom. This is security code: a future hardening (encoded secrets, multi-secret sets) wouldn't reach a lagging transport.

Plan (verified dep graph: ClawLLM/ClawTelegram/ClawTools each depend only on ClawCore): move `SecretRedactor` to `ClawCore` (e.g. `Domain/Support`); construct `SecretRedactor(secretValues: [<secret>])` at each of the three transports and call `.redact(_:)`; point `ExaSearchProvider` and `ExfilArgGuard.renderRedacted` at `SecretRedactor.replacement`; for `ExfilArgGuard`, promote the `secret-value` rule name to a constant and build the token via its existing `[REDACTED:\(rule)]` formatter so the redactor→guard direction is enforced in code. Update the two outlier test assertions (`OpenAICompatibleProviderTests` 198/365, `TelegramClientTests` 237). Do NOT add a second `redact(secret:in:)` helper alongside `SecretRedactor`.

### Agent runtime test doubles copied into two support files
- `Tests/ClawAgentTests/Support/AgentTestSupport.swift` :: `SequenceProvider` (67–82), `ScriptedDispatcher` (85–107), `EmptyWorkspace` (185–197), `EmptyMemoryStore` (201–210), `EmptyRetriever` (213–221), `RecordingAuditLog` (158–181, superset with scripted-throw init)
- `Tests/ClawGatewayTests/Support/AgentDoubles.swift` :: same six (12–27, 30–52, 107–119, 122–131, 134–142, 159–174) — `SequenceProvider`/`ScriptedDispatcher` byte-identical; `EmptyWorkspace` doc comment already diverged; `RecordingAuditLog` is the throw-less subset

Six doubles for the same six ClawCore protocols redefined per target — the largest test-tree duplication. `ClawTestSupport` depends only on ClawCore and already hosts this exact pattern (`FakeExecutionBackend`, `ScriptedClock`, `TypingIndicatorDoubles`); the Gateway file already imports it via the typing doubles.

Plan: add `Sources/ClawTestSupport/AgentRuntimeDoubles.swift` promoting the six as `public` (take the `RecordingAuditLog` superset). Delete both local copies; add `import ClawTestSupport` to `AgentDoubles.swift`. Free-function builders and Agent-only `RecordingUsageStore`/`StubProvider` are out of scope (not duplicated).

### Agent response/outcome builders copied byte-for-byte
- `Tests/ClawAgentTests/Support/AgentTestSupport.swift :: okResponse/okOutcome/toolCallResponse/fetchProposal` (290–336)
- `Tests/ClawGatewayTests/Support/AgentDoubles.swift :: okResponse/okOutcome/toolCallResponse/fetchProposal` (56–102)

Byte-identical, including defaults (`"Hello there"`, `ChatUsage(10,5,15)`, cost `0.0021`, `web_fetch`, id `c1`, `https://example.com/a`). `AgentDoubles.swift` self-documents as a duplicated mirror. All referenced types are ClawCore-only. Drift risk: a `ChatResponse`/`ToolDispatchOutcome` field or a cost/token baseline change updates one copy only.

Plan: add `Sources/ClawTestSupport/AgentWireBuilders.swift` (`import ClawCore`) with the four as `public`; delete from both files; add `import ClawTestSupport` to `AgentDoubles.swift`. No Package.swift change.

### Durable message-role/provenance vocabulary as inline SQL
- `Sources/ClawData/Stores/Run/RunStoreGRDB+TurnCommits.swift` (143, 240, 250)
- `Sources/ClawData/Stores/Run/RunStoreGRDB+SuspendResume.swift` (185, 191, 278, 295, 371, 380, 391)
- `Sources/ClawData/Stores/Session/SessionMessageStoreGRDB.swift` (73, 151) — decode path already uses the enums (244–249)
- `Sources/ClawData/Stores/Scheduling/ScheduledJobStoreGRDB.swift` (238, 566)
- `Sources/ClawData/Stores/Memory/RetrieverGRDB.swift` (32)
- `Sources/ClawData/Stores/Approval/ApprovalStoreGRDB.swift` (174)
- Canonical enums already exist: `Sources/ClawCore/Persistence/Persistence.swift :: Provenance / MessageRole` (67–77)

The `'user'/'assistant'/'tool'/'trusted'/'untrusted'` trust-model vocabulary is retyped as ~15 bare SQL literals across 6 files, even though the read/decode path routes through the enums and `RunState`/`ApprovalState` writes bind `.rawValue`. Correction to the raw finding: the claimed `USER_ROLE`/`TRUSTED_PROVENANCE` constants do NOT exist, and the enums already exist — the gap is that write/filter sites don't reference them. WHERE-clause filters have no fail-closed guard, so a typo mis-filters silently.

Plan: bind `MessageRole.*.rawValue`/`Provenance.*.rawValue` as `?` params on inserts; interpolate the enum `rawValue` into composed WHERE clauses. One compiler-checked source; a genuine rename still needs a data migration regardless.

### Telegram 32_768 per-message char limit duplicated
- `Sources/ClawCore/Domain/Delivery/ReplySplitter.swift :: limit` (8)
- `Sources/ClawTelegram/Client/TelegramRichDraftStreamer.swift :: maxMarkdownCharacters` (9)

Same protocol ceiling under two names (only two occurrences in the tree); splitter chunks to it, streamer truncates to it. Drift risk: a Telegram limit revision updates one, causing send rejections or mismatched truncation between committed reply and ephemeral draft.

Plan: own it in ClawCore (`TelegramMessageLimits.maxRichMessageCharacters = 32_768` in `Domain/Support`, or treat `ReplySplitter.limit` as canonical) and have the streamer consume it — NOT the reverse, since ClawCore cannot import ClawTelegram.

### Truncation marker `…[truncated]` defined twice
- `Sources/ClawAgent/Context/BudgetFitter.swift :: truncationMarker` (79)
- `Sources/ClawTools/Text/ToolOutputCap.swift :: truncationMarker` (8) — doc comment claims consistency yet copies the literal

Both reserve `marker.count` then append it when truncating to a grapheme budget; `ContextBuilder.swift:331` already reads `BudgetFitter.truncationMarker` as a single source, proving the pattern. Drift risk: editing one silently breaks the asserted invariant.

Plan: `public enum TextTruncation { public static let marker = "…[truncated]" }` in `ClawCore/Domain/Support`; both consumers reference it; reword the `ToolOutputCap` comment to "canonical, not copied".

### YYYY-MM-DD / wall-clock day formatting duplicated
- `Sources/ClawGateway/Response/MemoryReplies.swift :: formattedDayString/dayFormat` (118–123) — `ISO8601FormatStyle`, UTC-only, display
- `Sources/ClawGateway/Response/SchedulerHealth.swift :: dayString(for:timezone:)` (113–123) — `Calendar` + `%04d-%02d-%02d`, zone-aware, persistence key for `heartbeat_count_day`
- `Sources/ClawGateway/Response/ScheduleReplies.swift :: fireTime(_:timezoneId:)` (116–128) — same kernel plus ` %02d:%02d`
- Test mirror: `Tests/ClawGatewayTests/MemoryAcceptanceTests.swift:108`

Same zero-padded YYYY-MM-DD produced three ways; `fireTime`'s date portion is byte-identical to `dayString`. `dayString` is the persisted heartbeat stamp, so its format is load-bearing. Drift risk: the boundary stamp and display strings diverge for the same day-boundary concept.

Plan: add `wallClockDay(in: TimeZone)` and `wallClockMinute(in:)` to `ClawCore/Domain/Support/Date+UTCDay.swift` (fresh value-type `Calendar` per call — Sendable, no static formatter). `SchedulerHealth`/`ScheduleReplies` delegate (preserving the persisted format); `MemoryReplies` calls it with `.gmt` and drops its ISO8601 static; the test calls the same helper.

### Private-data prompt-file set `{MEMORY.md,USER.md}`
- `Sources/ClawTools/Tools/FileReadTool.swift :: readPrivateData check` (75–77)
- `Sources/ClawTools/Tools/ExecuteCodeTool.swift :: isPrivate(realpath:)` (446–452)

Both resolve `canonicalRoot` then do the identical two root-anchored equality checks against `/MEMORY.md` and `/USER.md` to gate the private-data tier. Drift risk: add/rename a private-tier file and the two tools' classification diverges — a security-relevant split. (The finding's third site, `TurnRunner+Payloads.isPrivilegedFile` `{SOUL,AGENTS,USER,MEMORY}`, is a different, larger set for a banner — excluded.)

Plan: add `WorkspaceFile.privateDataFiles = [.user, .memory]` and a root-anchored `isPrivateData(canonicalPath:canonicalRoot:)` to `WorkspaceFile.swift` (both tools already import ClawCore); both call it, preserving today's full-path semantics.

### HEARTBEAT_OK ack token in detector + prompt prose
- `Sources/ClawGateway/Routing/HeartbeatAck.swift :: token` (9)
- `Sources/ClawGateway/Services/Heartbeat/HeartbeatSettings.swift :: HeartbeatTemplate.contractSentence` (62) — prose "reply exactly HEARTBEAT_OK"

Producer/detector contract with the sentinel written once as a constant and once embedded in prose. Drift risk: change one and ack suppression breaks (every heartbeat delivered, or none). Both in ClawGateway.

Plan: interpolate `HeartbeatAck.token` into the contract sentence; convert `contractSentence` from `static let` to a computed `static var` (or `static func`) so the runtime interpolation is legal, keeping the trailing period as prose. Optionally assert the prompt contains the token.

### `ScriptedResolver` DNS double copied across two targets
- `Tests/ClawToolsTests/Tools/WebFetchToolTests.swift :: ScriptedResolver` (45–57)
- `Tests/ClawGatewayTests/Acceptance/SC3Harness.swift :: ScriptedResolver` (411–424) — byte-identical; consumed by SC3 + SC7 harnesses

`struct: AddressResolving` parsing IP literals via `ResolvedAddress.parse` else a `[String:[ResolvedAddress]]` table, throwing `AddressResolutionError.unresolvable`. Both consuming targets already link ClawTools + ClawTestSupport.

Plan: promote one `public ScriptedResolver` (optionally `TableAddressResolver`) into `ClawTestSupport`; because `AddressResolving` lives in ClawTools, add `"ClawTools"` to the `ClawTestSupport` target deps in `Package.swift:81` (no cycle). Delete both copies; the four call sites resolve automatically.

### `ScriptedHTTP` recording double duplicated 4×
- `Tests/ClawToolsTests/Tools/WebFetchToolTests.swift :: ScriptedHTTP` (9–42)
- `Tests/ClawGatewayTests/Acceptance/SC3Harness.swift :: ScriptedHTTP` (378–409) — near-identical, in-code comment admits the copy
- `Tests/ClawToolsTests/Search/ExaSearchProviderTests.swift :: ScriptedPostHTTP` (8–39) — POST sibling
- `Tests/ClawTelegramTests/Client/RichMessageTests.swift :: CapturingExecutor` (9–34) — POST sibling

All are hand-written `HTTPExecuting` doubles (one ClawCore protocol) that record the request and replay a scripted/canned `HTTPResult`, throwing on the unused verb.

Plan: add one configurable `public actor RecordingHTTPExecutor` to `ClawTestSupport` (URL-keyed map + optional canned fallback; records url/headers/body; both `get()`/`post()`). Retire all four; add `ClawTestSupport` to `ClawTelegramTests` deps in `Package.swift`. Leave `LLMTestSupport.ScriptedHTTPExecutor` as-is — its ordered-queue Step model + `HTTPStreaming` conformance serve distinct retry/stream tests.

### `ProviderUsage` fixture builder copied across Run tests
- `Tests/ClawDataTests/Stores/Run/RunStoreTests.swift :: usage(runId:sessionId:)` (49–61)
- `Tests/ClawDataTests/Stores/Run/PrivateDataLifecycleTests.swift :: usage(runId:sessionId:)` (45–57) — verbatim except `ts`
- `Tests/ClawDataTests/Stores/Run/ExchangeCommitTests.swift :: makeUsage(_:)` (38–50)
- `Tests/ClawDataTests/Stores/Run/OutboxStepSequenceTests.swift :: makeUsage(_:)` (157–169)
- `Tests/ClawDataTests/Stores/Run/RunsHealthTests.swift :: seedUsage(...)` (51–71, + inline at 86)

`ProviderUsage` is a durable 9-field persistence value type; the first pair is verbatim, the rest share the fixture shape with meaningful param variation (tokens, `isEstimated`, model, `costSource`). Drift risk: a new required field forces edits at every site.

Plan: add `Tests/ClawDataTests/Stores/Run/ProviderUsageFixtures.swift` with `makeProviderUsage(runId:sessionId:model:…:ts:)` defaulted; the two `usage`/`makeUsage` pairs and the fixture-taking wrappers forward into it; `seedUsage` keeps its record-into-store body but builds via the helper. Narrowest home is this directory; the same shape in ClawGateway/ClawLLM tests is a separate target and out of scope.

### `RecurrenceRule` fixture builders per scheduling suite
- `Tests/ClawCoreTests/Domain/Scheduling/OccurrenceCalculatorTests.swift :: weekdaySevenRule()/utcCalendar()` (36–65) — UTC (deliberate DST test), no seconds
- `Tests/ClawCoreTests/Domain/Scheduling/ScheduledJobTests.swift :: weekdaySevenBerlinRule()` (7–21) — Berlin, no seconds
- `Tests/ClawGatewayTests/Acceptance/SC7AcceptanceTests.swift :: berlinCalendar()/weekdaySevenRule()/dailySevenRule()/everyFiveMinutesRule()` (39–71) — Berlin, `seconds:[0]`
- `Tests/ClawGatewayTests/Services/SchedulerServiceTests.swift :: everyFiveMinutesRule()` (202–205) — identical every-5-min
- `Tests/ClawDataTests/Stores/Scheduling/ScheduledJobStoreGRDBTests.swift :: weekdayEnvelope()` (24–37) — Berlin, no seconds

Two exact-copy pairs (every-5-min; Berlin Mon–Fri 07:00 no-seconds) plus a recurring gregorian+Berlin calendar builder. Correction: the OccurrenceCalculator rule is deliberately UTC (verifies DST propagation) and SC7's weekday/daily rules add `seconds:[0]` — so the fix must parameterize zone and seconds, not assume one canonical Berlin rule.

Plan: add `Sources/ClawTestSupport/SchedulingRuleFixtures.swift` with parameterized builders — `calendar(zone:)`/`berlinCalendar()`, `weekdaySeven(zone:seconds:)`, `dailyAt(hour:minute:zone:seconds:)`, `everyNMinutes(_:zone:)`, `weekdayEnvelope(...)`. Add `"ClawTestSupport"` to `ClawDataTests` deps. Replace the five locals, passing UTC (with its explanatory comment) at the OccurrenceCalculator site and `seconds:[0]` at SC7.

### Scheduling anchor timestamps as magic literals
- Anchor `1_783_339_200` (Mon 2026-07-06 12:00 UTC / 14:00 Berlin) and next-fire `1_783_400_400` (Tue 07:00 Berlin) recur across 9 files: `OccurrencePolicyTests.swift:10` (comment wrongly says 2026-07-07), `ScheduleDraftValidatorTests.swift:7`, `ScheduleCommandStoreTests.swift:9/33/51`, `SC7Harness.swift:144`, `SC7AcceptanceTests.swift:15–18`, `ScheduleRoutingTests.swift:12/150/204`, `ScheduleVerbRoutingTests.swift:12–14`, `ScheduleInteractionTests.swift:11`, `SchedulerHeartbeatTests.swift:28`

One deliberately DST-free anchor pair re-declared and re-explained per file; drift already realized (the incorrect date comment).

Plan: add `enum SchedulingTestClock { static let mondayNoonBerlin = Date(...1_783_339_200); static let tuesdaySevenBerlin = Date(...1_783_400_400) }` to `ClawTestSupport`, documented once (optionally fold in the DST/pastDue anchors). Add `"ClawTestSupport"` to `ClawDataTests` deps; replace the ~15 literal sites; fix the wrong comment. For the OccurrencePolicy UTC-noon usage, reference directly or add a neutrally-named alias.

### Duplicate OpenAI wire `Usage` decode struct
- `Sources/ClawLLM/Provider/SSEParser.swift :: Usage` (301–313)
- `Sources/ClawLLM/Provider/OpenAICompatibleProvider.swift :: ResponseBody.Usage` (455–467)

Field-for-field and CodingKey-for-CodingKey identical (`prompt/completion/total_tokens` `Int?`, `cost` `Double?`), both `private`, both in ClawLLM, both mapped into `ChatUsage` via the same `?? 0` pattern. Drift risk: a new usage field (e.g. cached tokens) added to one leaves streaming/blocking paths inconsistent.

Plan: one internal `struct WireUsage: Decodable` in `ClawLLM/Provider`; both `Chunk.usage` and `ResponseBody.usage` decode into it; optionally add `toChatUsage()`.

### Case-insensitive `getHeader` on two HTTP value types
- `Sources/ClawCore/Transport/HTTPExecuting.swift :: HTTPResult.getHeader(for:)` (14–17)
- `Sources/ClawCore/Transport/HTTPExecuting.swift :: HTTPStreamHead.getHeader(for:)` (29–32)

Byte-identical `first { $0.key.lowercased() == target }?.value` over `[String:String]` headers in the same file. No shared helper exists.

Plan: add a file-scoped `extension Dictionary where Key==String, Value==String { func caseInsensitiveValue(for:) }` (or a `HeaderCarrying` protocol with a default `getHeader`); keep both public `getHeader(for:)` methods delegating so external callers (`WebFetchTool`, `OpenAICompatibleProvider`) and tests are unchanged.

### Positive-Int64 arg parser in bot command handling
- `Sources/ClawCore/Domain/Bot/Command.swift :: jobId(from:)` (112–118) — trims then `Int64 > 0`
- `Sources/ClawCore/Domain/Bot/MemoryCommands.swift :: MemoryCommand.positiveId(_:)` (85–90) — pre-split token, no trim

Same "positive Int64 or nil" rule in the same folder; the token at line 50 is whitespace-free so a trimming helper is behavior-preserving for both.

Plan: `enum PositiveInt64 { static func parse(_:) -> Int64? }` in `Domain/Bot`; `jobId` becomes `PositiveInt64.parse(arguments)`; delete `positiveId` and update its one call site (`MemoryCommands.swift:71`).

### LLM run-bound defaults `EnvDefaults`↔`RunBudget.default`
- `Sources/ClawCore/Config/AppConfig.swift :: EnvDefaults` (49–55) — `maxOutputTokens=4096`, `retryBudget=3`, `proactivePerDayUSD=2.00`
- `Sources/ClawCore/LLM/RunBudget.swift :: RunBudget.default` (58,60,63) — same three values

The daemon builds `RunBudget` from `EnvDefaults` (parseBudget), so `RunBudget.default`'s copies of those three are a stale-able shadow read only by direct consumers/tests. Correction: the fourth cited value (180) is a false conflation — `requestTimeoutSeconds` (per-request HTTP) and `wallClockDeadlineSeconds` (whole-run) are different concepts wired from different sources; exclude it.

Plan: `enum RunDefaults { static let maxOutputTokens=4096; retryBudget=3; proactivePerDayUSD=2.00 }` in `ClawCore/Domain/Support`; both `EnvDefaults` and `RunBudget.default` reference it. Do NOT invert the dependency (domain→config). Leave the 180 pair independent.

### Sandbox container resource defaults across config layers
- `Sources/ClawCore/Config/AppConfig.swift :: EnvDefaults.execMemoryMiB/execCPUs/execTimeoutSeconds` (66–68)
- `Sources/ClawCore/Config/ExecConfig.swift :: disabledDefault` (136–144) — re-hardcodes 1024/4/30

The parser treats `EnvDefaults` as authoritative; `disabledDefault` re-types the triple, so a changed env default leaves the disabled-sandbox fallback stale. Same drift on `imageRegistryAllowlist ['cgr.dev']` vs `EnvDefaults.execImageRegistries`.

Plan: point `disabledDefault`'s three fields (and the registry allowlist) at `AppConfig.EnvDefaults.*`. No new type.

### Approval-expiry default 3600 in AppConfig + TurnRunner
- `Sources/ClawCore/Config/AppConfig.swift :: EnvDefaults.approvalExpirySeconds` (61)
- `Sources/ClawGateway/Turn/TurnRunner.swift :: init(approvalExpirySeconds:) default` (78)

Production injects `config.approvalExpirySeconds`; TurnRunner's `= 3600` is a test-convenience fallback reached only by ~7 test call sites that omit the arg. Drift risk: spec default changes, tests exercise stale expiry.

Plan: do NOT reference `EnvDefaults` (it's internal to ClawCore; TurnRunner is in ClawGateway). Drop the `= 3600` default and require injection — matching the sibling `parker` param that already carries no default. Update the ~7 test sites (ideally via one shared ClawGateway test constant).

### `CLAW_*` secret env-var names outside `EnvKey`
- `Sources/ClawSecrets/EnvSecretStore.swift :: EnvKey.botToken/llmApiKey/searchApiKey` (7–11)
- `Sources/clawd/Subcommands/SecretsCommand.swift :: Seal.run() success message` (57–58) — prose literals

`EnvKey` (public) is the canonical home; the seal "you may now remove …" guidance re-types the three names. Drift risk: a rename leaves stale guidance.

Plan: interpolate `EnvSecretStore.EnvKey.botToken/llmApiKey/searchApiKey` into the message (already imported, public).

### Approval `"PENDING"` hardcoded in DB index condition
- `Sources/ClawData/Database/ClawDatabase.swift :: v8 partial-index condition` (238) — `Column("state") == "PENDING"`
- `Sources/ClawCore/Domain/Approval/ApprovalFSM.swift :: ApprovalState.pending` (4) — rawValue `"PENDING"`

The store binds `ApprovalState.pending.rawValue` at all 7 sites; only the migration's live partial-index predicate (one-pending-per-run) hardcodes the string. The file already imports ClawCore.

Plan: `condition: Column("state") == ApprovalState.pending.rawValue` — evaluated at migration-build time, emits identical DDL, frozen v8 schema unchanged, and a future rawValue change surfaces at compile time.

### `HangingProvider` deadline-losing double per module
- `Tests/ClawAgentTests/Support/AgentTestSupport.swift :: HangingProvider` (40–48) — actor, sleeps 3600s then RETURNS late `ChatResponse`, unused `calls`
- `Tests/ClawGatewayTests/Routing/ScheduleDraftParserTests.swift :: HangingProvider` (232–237) — struct, sleeps 3600s then THROWS `.terminal`

Same double (a provider that loses to the wall-clock deadline). The divergent post-sleep branch is dead code (the injected clock fires the deadline, `sleep` is cancelled), so the drift is inert but still a second copy; `ClawTestSupport` hosts no provider double yet.

Plan: promote one `public struct HangingProvider: LLMProvider` (pick one behavior — throw `.terminal`; drop the unused `calls`) to `ClawTestSupport`; delete both locals (both files already import it). Fold into the same promotion pass as the agent-runtime doubles.

### `runStates(databasePath:)` query helper copied 3×
- `Tests/ClawGatewayTests/Acceptance/ApprovalDoneWhenTests.swift` (43–48)
- `Tests/ClawGatewayTests/Acceptance/SC3AcceptanceTests.swift` (319–324)
- `Tests/ClawGatewayTests/Routing/ToolApprovalRoutingTests.swift` (16–21)
- Home: `Tests/ClawGatewayTests/Support/ApprovalTestSupport.swift :: runState(databasePath:runId:)` (106)

Byte-identical `SELECT state FROM runs ORDER BY id`, the plural sibling of the already-shared `runState`. The three copies also miss the shared helpers' `SnapshotPoolCache` optimization despite running in `pollUntil` loops.

Plan: add one non-private `runStates(databasePath:)` to `ApprovalTestSupport.swift` after `runState`, switching to `SnapshotPoolCache.shared.pool(at:)`; delete the three copies (same target, no imports).

### `makeStateRoot()` temp-dir factory in every secrets test
- `Tests/ClawSecretsTests/EncryptedFileSecretStoreTests.swift` (10, prefix `claw-secrets`)
- `Tests/ClawSecretsTests/KeyFileSecurityTests.swift` (14, `claw-keysec`)
- `Tests/ClawSecretsTests/SecretStoreResolverTests.swift` (10, `claw-resolve`)
- `Tests/ClawSecretsTests/SecretsDoctorRowTests.swift` (10, `claw-doctor`)

Four identical UUID-suffixed temp-dir factories differing only by prefix; the same shape recurs across ClawData/ClawTools/ClawCore tests too.

Plan: promote `makeTemporaryRoot(prefix:)` into `ClawTestSupport` (the cross-module home); add `"ClawTestSupport"` to `ClawSecretsTests` deps (currently missing); replace the four with `makeTemporaryRoot(prefix: "claw-…")`.

### Temp SQLite path helper open-coded ~6×
- `Tests/ClawGatewayTests/MemoryAcceptanceTests.swift :: makeTempDatabasePath()` (37) — already a private helper
- `Tests/ClawGatewayTests/AcceptanceTests.swift` (13), `LLMTurnPersistenceAcceptanceTests.swift` (843)
- `Tests/ClawDataTests/Database/ClawStoresTests.swift` (10, 26), `Stores/Session/UpdateCursorStoreTests.swift` (47)

`NSTemporaryDirectory() + "claw-<prefix>-\(UInt64.random…).sqlite"` copied across two targets, each paired with the same cleanup `defer`. One site already named it.

Plan: add `public func makeTempDatabasePath(prefix:) -> String` to `ClawTestSupport`; add `"ClawTestSupport"` to `ClawDataTests` deps (line 111); replace all six, leaving each existing cleanup `defer` in place. A single shared home beats the finding's proposed per-target helpers (which would remain two copies).

## Quick wins

Lowest-effort, highest-payoff — mechanical, mostly single-file or single-line:

- Reference the existing canonical symbol instead of a literal: `HEARTBEAT_OK` token, approval `"PENDING"` index condition, `CLAW_*` env-var names, `SecretRedactor.replacement` at the ExaSearchProvider/ExfilArgGuard sites, and `disabledDefault`→`EnvDefaults` sandbox resource defaults. Each is a few characters, no new type.
- Promote the epoch-second codec to `EpochSecondCodec` in `ClawData/Database` and rename ~30 `Self.epoch`/`Self.date` call sites — one of the highest-value correctness fixes and pure find/replace.
- Route `MemoryWriteArguments.canonicalTarget` through `SHA256Digest.hex(...).prefix(16)` (two-line change + drop `import Crypto`), removing the third copy of the `%02x` idiom on the approval-identity path.
- Collapse the two ClawTools canonical-JSON encoders onto one `CanonicalJSON.encode` — small, and it hardens a security boundary.
- Constants with clean single homes: `TextTruncation.marker`, `TelegramMessageLimits.maxRichMessageCharacters`, `ExecStagingLimits.default`.
- Test-support batch: do the `ClawTestSupport` promotion once and land the agent-runtime doubles, agent wire builders, and `HangingProvider` together (all reference only ClawCore, both targets already import the module).

## Notes & limitations

- The audit is map-based and sliced per hunter category (util-helpers, logic-patterns, constants-literals, types-models, protocol-conformance, test doubles, test helpers/fixtures). That's why the same defect (epoch codec, config parser, header lookup, canonical JSON, SHA256 target, doctor rows, secret redaction) appears under several lenses; the 46 raw findings were de-duplicated to 33 distinct defects here.
- Every location, line hint, and "no third copy exists" claim was traced through real code by a verification pass. Where a hunter's supporting detail was wrong it is corrected in-line rather than dropped: the non-existent `USER_ROLE`/`TRUSTED_PROVENANCE` constants (role/provenance finding), the 180-second false conflation (RunBudget defaults), the `TurnRunner+Payloads` privileged-set false linkage (private-data files), and the UTC-vs-Berlin / seconds variation the "same rule everywhere" framing hid (recurrence fixtures).
- Impact ratings reflect the actual threat model, not raw severity labels. Several high-severity-looking items are low real-world impact because a rename would need a data migration anyway (role/provenance vocabulary), the drift sits in dead code (`HangingProvider`), or the stale copy is test-only (RunBudget defaults, approval-expiry 3600).
- Scope boundaries the audit deliberately respected: cross-module concept splits that only *look* like duplication were excluded (`LLMTestSupport.ScriptedHTTPExecutor`'s queue/streaming model; `ScheduledJob`/`PolicyFingerprint`/`DoctorReport` JSON encoders that use a *different* `outputFormatting`; the `PolicyFingerprint` streaming digest, which shares only the hex tail). Package-graph wiring is a real gate for four test-support consolidations — `ClawTestSupport` would need a `ClawTools` dependency (ScriptedResolver), and `ClawDataTests`/`ClawSecretsTests`/`ClawTelegramTests` would each need a `ClawTestSupport` dependency added — none of which introduces a cycle.
- What the slicing could not see: cross-file semantic clones that don't share a symbol name or literal, and duplication inside files not selected into the 55-candidate hunt. Absence of a finding in an area is not proof it's clone-free.
