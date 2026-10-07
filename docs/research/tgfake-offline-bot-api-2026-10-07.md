# tgfake as an offline Telegram stand for swift-claw

Date: 2026-10-07.
Scope: [tgfake](https://github.com/EvilFreelancer/tgfake) v1.0.0
([`bc4067a`](https://github.com/EvilFreelancer/tgfake/commit/bc4067a15ad05b353052cd87bf5915cb6e77d521)),
swift-claw `main` from `af423fb3` to `9f429462`.
Status: research. This report is evidence, not a specification.

Evidence labels:

- **[run]**: verified by running a binary or a test on 2026-10-07.
- **[code]**: read in source.
- **[docs]**: stated in the official Bot API pages (https://core.telegram.org/bots/api and the
  changelog), read on 2026-10-07.
- **[inferred]**: reasoning that was not checked.

## Summary

tgfake can drive the real `clawd` binary end to end without a token, a phone or network access.
It does not belong in `swift test`: it needs an external Go binary, real time and real sockets,
which [TESTING.md §6](../TESTING.md#6-stability-and-determinism) keeps out of the deterministic
suite. Its value is an optional end-to-end layer over the real process: environment loading, the
real HTTP stack, long polling, shutdown and restart.

One short trial against v1.0.0 found a false error log on shutdown, fixed in
[`552aa90c`](https://github.com/ivan-magda/swift-claw/commit/552aa90c5989f6278dc3ab5850cc710a6f0e2e08).
Mapping the gaps then found an outbox defect that silenced the bot after one long reply, fixed in
[`9f429462`](https://github.com/ivan-magda/swift-claw/commit/9f42946253d9227a27ef5104bfee3182223a906f);
see [side findings](#side-findings-in-swift-claw).

v1.0.0 does not model several paths swift-claw depends on: keyboards on rich messages, the native
draft Stop, forum topics, inbound media, `getChatMember`, and edited or membership updates. Two of
them were closed as tgfake prototypes with tests, sized S and M. Covering every path is estimated
at 2,100–3,000 lines and 9–14 developer days. Most of the uncertainty is what real Telegram
answers where the documentation is silent.

## What tgfake is

- A fake Bot API at `<origin>/bot<token>/<method>`. It accepts any token unless one is fixed, and
  reads form, JSON and multipart bodies [code].
- A simulation API under `/sim/`. A test injects messages and button taps, reads the transcript
  and every Bot API call, and schedules faults such as 429, 5xx, 403 or 409 [code].
- A chat page for manual use, and `--llm`, a scripted OpenAI-compatible model with rules, tool
  calls and SSE streaming [code].
- It refuses what Telegram refuses on the paths it implements: edits that change nothing,
  `callback_data` over 64 bytes, a second answer to one callback query, and `sendMessage` text
  over 4,096 characters [code].
- MIT licence, a static release binary, a GitHub Action, and Go 1.22+ [code]. The first release
  was published on 2026-10-07; GitHub listed two contributors that day.

## Trial against the real daemon

`clawd` has no setting for the Telegram API address: `TelegramClient` accepts `baseURL`, but
`RunComposition` never passes it (`Sources/clawd/Composition/RunComposition.swift`). The trial
used a temporary, uncommitted override read from `CLAW_TELEGRAM_API_BASE_URL`. The environment was
clean: a throwaway state root and `HOME`, a fake token, owner `4242` (tgfake's default user), and
the OpenAI-compatible route pointed at tgfake's `--llm` model with zero prices. The LLM side
needed no code change.

| Scenario | Result |
| --- | --- |
| Smoke: owner message to streamed answer | [run] `getMe`, `setMyCommands`, long poll, typing, two `sendRichMessageDraft` revisions (`draft_id` -1, `can_stop`, `keep_on_stop: false`), then `sendRichMessage`; answer about 1.0 s after the message; all calls 200. The SSE parser accepted tgfake's stream including its usage chunk. |
| Commands | [run] all 15 menu commands registered. |
| Default-deny | [run] user 5555 got the "private bot" reply; no turn started for that update. |
| Shutdown during a held long poll | [run] exit 0 in 0.02–0.04 s. Before `552aa90c` every such stop logged `telegram error: transport(... CancellationError())` at `error`; after it, none. |
| Restart with an unconfirmed update | [run] the update was processed, its confirming poll got a scheduled 502, and the process was stopped. After restart `clawd` polled from its persisted offset, so the update was not redelivered and was answered once. The redelivery dedup path is therefore not exercised this way. |

## Gaps in tgfake v1.0.0

| # | Gap | swift-claw path | Telegram behavior | Size |
| --- | --- | --- | --- | --- |
| 1 | `sendRichMessage` drops `reply_markup` | Approval and feedback keyboards ride rich messages (`OutboxDispatcher`) | [docs] documented parameter | S, prototyped |
| 2 | No `can_stop`, `keep_on_stop` or `stopped_message_generation` | Native draft Stop (architecture §6.6) | [docs] added in Bot API 10.3 (2026-08-24); later revisions of a stopped draft undocumented | M, prototyped |
| 3 | A draft stays up to 30 s after the final message | Presentation leases assume Telegram clears drafts | [docs] partly: only the `keep_on_stop` text says a bot message removes the draft | S |
| 4 | Forum topics not modelled | Group mode sessions and topic replies (§12.1) | [docs] fields documented; General-topic and refusal details not | L, 500–800 lines |
| 5 | No inbound photo, voice or document; no `getFile` or file download | Vision and voice paths, unsupported-media replies | [docs] mostly; refusal texts and `file_path` shape not | M minimal, L full |
| 6 | `getChatMember` returns 404 | Group Coder approvals | [docs] partly | M; low e2e value |
| 7 | No `edited_message` or `my_chat_member` updates | Edited turns; membership log | [docs] documented | S–M each |
| 8 | No length or chat-type checks on rich sends and drafts | Splitter limits | [docs] 32,768 "UTF-8 characters"; refusal texts not documented | S after capture |

Other notes:

- `link_preview_options` is recorded and ignored by tgfake, and it is not a documented parameter
  of `sendRichMessage` or `sendRichMessageDraft` [docs].
- Rate limits and 409 Conflict are not modelled; faults cover both deterministically.
- Group mentions, replies to the bot and `reply_parameters` already work.

## Prototype calibration

Two gaps were implemented in a scratch copy of tgfake and then split into two independent
branches off its `main`, following its rules: a failing test first, Gherkin for the new
capability, refusals as unit tests, documentation in the same change.

| Branch | Change | Lines |
| --- | --- | --- |
| `rich-message-keyboard` | `sendRichMessage` validates and keeps `reply_markup` with `sendMessage`'s checks | +72 / −4, 3 files |
| `draft-stop` | Per-revision `can_stop`, `keep_on_stop`, `message_thread_id`; `POST /sim/draft/stop`; the new update kind under `allowed_updates`; `[Stop]` in the transcript and on the chat page | +264 / −19, 13 files |

Results [run]: `go vet`, `go test -count=1 ./...`, `go test -race`, golangci-lint v2.12.2 and
`go mod tidy -diff` pass on each branch. The Gherkin run passed 3 of 3 scenarios. The new keyboard
tests fail on tgfake `main`. The Stop button was pressed on the chat page in a browser and
produced the update. Driven with requests shaped like `clawd`'s, v1.0.0 gives no keyboard, a
failed tap, a false "message is not modified" on the disarm edit and a 404 for Stop; the branches
give the keyboard, the tap, the disarm and the update. The two branches touch neighbouring rows of
one table in tgfake's `docs/bot-api.md`, so the second to merge needs a one-line merge. Not
verified: the Go 1.22 toolchain in tgfake's CI matrix.

Estimates made before coding were 60–80 and about 250 lines; the results were 72 and 264. The
calibration holds for gaps with documented behavior and small state (#1, #2, #3, #7). For #4, #5,
#6 and #8 the main cost is capturing real Telegram answers, which needs a real bot.

## Recommendation

- Keep tgfake out of `swift test` and out of required CI. The Swift doubles (`RecordingTransport`,
  scripted HTTP executors, `CompositionAcceptanceHarness`) cover the logic at its seams; tgfake
  complements them with real-process checks.
- Contribute upstream rather than fork: #1 and #2 first, then #5 starting with photos, then #7.
  Take #4 in phases. Gather real Telegram answers before #3, #8 and the refusals in #4–#6. Leave
  #6, rate limits and 409 to the Swift doubles and tgfake faults.
- Effort: about 950 lines and 3–4 days for #1, #2, minimal #5 and edited messages; about
  2,100–3,000 lines and 9–14 days for every path. Upstream review time is extra.

swift-claw-side work, outlined only:

1. A Telegram API base URL setting. The bot token travels in every request path, so it is
   security-relevant: https only, plain http only for loopback; reject userinfo, query, fragment
   and paths; a boot warning and a `doctor` row when it is not the default; applied to both
   `RunComposition` and `DoctorCommand`; documented in architecture §15, `.env.example` and the
   public guides.
2. An opt-in end-to-end script: start tgfake (release or a pinned patched build) and `clawd run`
   with a throwaway state root, then run the trial scenarios above, the approval round trip (#1),
   Stop during streaming and during an approval wait (#2), and fault scenarios. Bound every wait.

## Side findings in swift-claw

1. **Outbox stall after one long reply.** [run] Outbox chunks are sized for rich messages (up to
   32,768 characters, `ReplySplitter`), but the plain fallback re-sent the same text with
   `sendMessage`, whose limit is 4,096. With a 5,410-character answer whose rich send was refused,
   the fallback failed with "message is too long"; the dispatcher stopped the drain on that row
   at every poke and after restart, so the next answer was never attempted. Any permanent refusal
   (400 or 403) had the same effect. Fixed in `9f429462`: the plain fallback sends parts of at most
   4,096 characters, and rows Telegram refused with 400 or 403 become `FAILED`. The same scenario
   then delivered both answers (architecture §6.4).
2. **Link previews on rich messages.** [docs] `link_preview_options` is not documented for the
   rich methods, while `LinkPreviewOptions`' comment relies on it to stop Telegram fetching URLs
   from outbound text, including attacker-chosen URLs in approval prompts. Whether rich messages
   build link previews at all is unknown and needs a live check.
3. **Length units.** [inferred] `ReplySplitter` and the draft caps count Swift `Character`s, while
   Telegram documents the rich limit in "UTF-8 characters". A chunk that passes the splitter could
   exceed Telegram's count. Needs a live check.
4. **Reply threads in non-forum supergroups.** [docs, inferred] `Message.message_thread_id` covers
   "a message thread or forum topic" in supergroups, and swift-claw keys topic sessions on it
   without reading `is_topic_message`. If Telegram sets it on reply threads in an ordinary
   supergroup, one room would split into several sessions. Needs a live check.

## Not verified

- Real Telegram refusal texts and undocumented behavior for #3–#6, #8 and 409; these need a real
  bot token.
- `clawd` against the prototype branches; they were driven with `clawd`-shaped requests instead.
- Voice transcription end to end, which needs macOS 26 and a recorded speech fixture.
