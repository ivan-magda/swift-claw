I'll answer as a world-renowned Computer Science researcher PhD with the ACM Turing Award.

**TL;DR**: Telegram Bot API 10.1 (released June 11, 2026) **officially adds** `sendRichMessage`, `sendRichMessageDraft`, and a `rich_message` parameter to `editMessageText`. These methods use an `InputRichMessage` object (with `html` or `markdown` fields) instead of plain text. The rich-message system supports advanced formatting (native headings, lists, tables, footnotes, etc.). Draft messages are *ephemeral previews* (30s lifetime) that must be finalized by calling the corresponding send method. Legacy text-mode still exists (plain text + `MessageEntity` arrays), with a few new entity types (e.g. `blockquote`, `expandable_blockquote`, `date_time`) and offsets counted in UTF-16 code units. Implementation simply requires sending JSON with the `rich_message` field; no manual Markdown-to-entity conversion is needed. Given its novelty, I recommend adopting rich-message streaming now **cautiously** (with a fallback to traditional methods), since a single-owner setup can tolerate early bugs, and the richer output and higher limits (32K vs 4K chars) are advantageous.

## Verification (Official Bot API 10.1)  
All requested features are **present in the official Telegram Bot API v10.1** (June 11, 2026). The changelog explicitly notes: “*Added the method sendRichMessage… Added the method sendRichMessageDraft… Added the parameter rich_message to the method editMessageText*”. The Bot API documentation confirms each signature:

- **sendRichMessage** – Parameters (excerpt):  
  - `chat_id` (Integer or String, *required*): target chat (user, group, or channel).  
  - `rich_message` (InputRichMessage, *required*): the message content (either `html` or `markdown`).  
  - Optional flags like `disable_notification`, `reply_markup`, etc. (as in normal sendMessage).  
  For example, the docs list `rich_message InputRichMessage Yes – The message to be sent`.

- **sendRichMessageDraft** – Parameters (excerpt):  
  - `chat_id` (Integer, *required*): target private chat only.  
  - `draft_id` (Integer, *required*): a non-zero identifier for this draft (updates with same ID are animated).  
  - `rich_message` (InputRichMessage, *required*): the partial content to stream.  
  The docs state this returns `True` and note it’s a “temporary 30-second preview” requiring a final `sendRichMessage`.

- **editMessageText** – Parameters updated:  
  - Now accepts an optional `rich_message` (InputRichMessage) parameter, which may be used *instead of* the `text` field (if `rich_message` is present, `text` is optional). The docs say: “`rich_message InputRichMessage Optional. New rich content of the message; required if text isn't specified.”.  

These signatures exactly match the versions in the official docs. In contrast, no such methods exist prior to v10.1; the previous streaming method was **sendMessageDraft** (Bot API 9.3, 2025) for plain text only. (If the new methods didn’t exist, we’d note that, but here they are verified.)

## Capabilities and Constraints  

| **Feature / Constraint**            | **Detail**                                                                                                 |
|-------------------------------------|------------------------------------------------------------------------------------------------------------|
| **Introduced in Bot API**           | 10.1 (June 11, 2026). Previous streaming method was `sendMessageDraft` (Bot API 9.3, Aug 2025). |
| **Rich message format**             | Uses `InputRichMessage` with either `html` or `markdown` content fields. All content must go via this object (no `parse_mode` needed).  |
| **Allowed formatting (rich)**       | Headings, nested lists, tables, block quotes (expandable), footnotes, math formulas, code blocks, task lists, etc.. Media blocks and advanced tags (e.g. `<u>underline</u>`, `<sup>`, `<sub>`, `<details>`, `<tg-spoiler>`, collages/slideshows) are supported in HTML mode. |
| **Entity model (legacy)**           | Plain-text sends still use `text` + `entities`. Supported `MessageEntity` types include all old ones (bold, italic, code, pre, URL, mention, etc.) plus new ones: **`blockquote`**, **`expandable_blockquote`**, **`date_time`**. Offsets/lengths are in UTF-16 code units.  |
| **Character limits**                | **Rich messages:** up to **32768 UTF-8 chars** in content (significantly above old 4096 limit). **Blocks:** max 500 (nested). (Old `sendMessage` still 4096-char per message.) |
| **Chat context**                    | `sendRichMessage` works in any chat (private, groups, channels) just like `sendMessage`.  **Draft streaming** (`sendRichMessageDraft`/`sendMessageDraft`) is **private-chat only** (per docs, “target private chat”). Bot-to-bot or channel topics not supported in draft methods. |
| **Draft lifetime**                  | Ephemeral preview lasting **30 seconds**. After 30s the draft vanishes; you must finalize before expiry by sending the full message. |
| **Rate limits**                     | Subject to standard Bot API limits (~30 queries/sec global, ~1/sec per chat/user) (not explicitly documented per-method, but consistent with Telegram’s overall limits). Streaming updates can hit these limits if called too fast. |
| **Client requirements**             | Clients must support rich formatting. Modern Telegram apps (desktop/mobile) released after late 2023 should handle rich messages; older/custom clients may fall back to plain text. According to adapter docs, on API 10.1+ rich markdown (headings, tables, etc.) is native, while older servers “automatically fall back to the existing path”. (In practice, unsupported features likely appear as raw text or simple HTML on old clients.) |
| **Graceful degradation**            | If the user’s Telegram client doesn’t support rich content, the message body will display without advanced styling (typically showing plain text or basic HTML). Older Bot API versions simply ignore unknown parameters, so bots can detect absence of `sendRichMessage` method as a signal to use legacy sends. For example, the chat-adapter notes that older/custom servers fall back to the standard MarkdownV2 path if rich methods are unavailable. |

## Streaming Mechanism Comparison  

- **Rich-message drafts (`sendRichMessageDraft`)** – Introduced in Bot API 10.1. Each call sends a partial rich-formatted message to the user’s chat *previewing* the output. The draft is ephemeral (30s); sending multiple updates with the same `draft_id` animates the updates (Telegram replaces the preview in place). During streaming, the user sees the rich content (tables, headings, etc.) build up. Once generation is complete, the bot must call `sendRichMessage` with the full `rich_message` to make the message permanent. If the final `sendRichMessage` is omitted or delayed past 30s, the draft preview disappears. (A noted issue: some bot frameworks have reported that improper finalization flags can cause the final message to revert to plain MarkdownV2 instead of using `sendRichMessage`, so care is needed to invoke the rich send path when done.)

- **Plain-text drafts (`sendMessageDraft`)** – Older analog (Bot API 9.3). Works the same way for simple text: streams a text preview in a private chat, then requires a `sendMessage` to finalize. No support for advanced formatting beyond Markdown/HTML.

- **Throttled editing (`editMessageText`)** – Legacy approach before draft methods. Bot first sends an initial message (usually with placeholder), then repeatedly calls `editMessageText` to update the content. Each edit replaces the message’s text. Downsides: edits are rate-limited (roughly 1 edit/sec per chat) and the entire message must be resent each time. In addition, content is still subject to the 4096-character limit (so very long messages require chunking into multiple messages or edits). There is no ephemeral “thinking” placeholder except using `sendChatAction`. This approach works in any chat, but is slower and uses up multiple edits (which can hit rate limits). In contrast, draft streaming avoids the need for an initial send and can stream the full content fluidly (up to the higher rich-message limits) with fewer requests.

In summary, `sendRichMessageDraft` is conceptually similar to `sendMessageDraft` (an improved version of streaming) but outputs rich content. Its lifecycle is: **create draft → update draft (with same ID) → finalize with sendRichMessage**. By comparison, the old method used `sendMessageDraft` (text) and the slow editing path (`sendMessage` + repeated `editMessageText`). The rich draft method yields a better user experience (structured formatting, higher limits) but is brand-new, so one should watch out for potential formatting bugs (as reported in developer forums).

## Recommendation  

For a single-owner assistant bot, **adopt rich-message streaming now** but with caution. The benefits are substantial: one can send much larger messages (up to ~32K chars) and richly formatted content (tables, headings, etc.) in a single flow, improving readability. The new API also simplifies implementation (you just pass your Markdown/HTML into `rich_message` instead of juggling parse modes or manual entity lists). However, it is very new and may have teething problems. To mitigate risk, implement a fallback path: for example, detect if `sendRichMessage` fails (or skip if not supported), and fall back to the old `sendMessage+edit` approach. Since this is a private chat with presumably up-to-date Telegram clients, compatibility should be fine for the developer. Given the caveat from early user reports, I would proceed with **rich streaming as the primary method**, but keep `editMessageText` (or throttled HTML `sendMessage`) as a fallback. 

In short, if you want the advanced formatting and higher limits, switch to `sendRichMessage`/`sendRichMessageDraft` now. The main downsides are moderate implementation effort (new JSON fields) and the instability of a brand-new API. For a single-user bot this risk is acceptable. If ultimate stability is paramount (e.g. a high-stakes production bot with many users), one might delay full adoption until more experience is gathered. But for a personal assistant scenario, rich messages are worth trying immediately with appropriate fallback logic. 

**Sources:** Official Telegram Bot API docs/changelog (core.telegram.org), which confirm method signatures and versions. Formatting details are from the “Rich Message Formatting” section of the docs. Entity types and UTF-16 offset rules are from the MessageEntity definition. Additional insights on drafts and streaming come from the docs and community reports.