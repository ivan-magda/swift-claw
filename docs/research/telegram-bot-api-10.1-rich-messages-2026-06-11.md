# Telegram Bot API 10.1 — Rich Messages

**Released:** June 11, 2026 (Telegram Desktop 6.9)

## New API Surface

- `sendRichMessage` — send a document-grade rich message
- `sendRichMessageDraft` — stream a partial rich message while generating
- `editMessageText` — new `rich_message` parameter to edit rich messages

## Supported Formatting

Tables, headings (H1–H3), ordered and unordered lists, collapsible detail sections, block and pull quotes, horizontal dividers, inline media with captions, math formulas, footnotes.

## Wire Format

Markdown string → `(plain_text, [MessageEntity])` — the same `MessageEntity` system Telegram already uses, extended with new entity types: `RichTextBold`, `RichTextItalic`, `RichTextUnderline`, `RichTextStrikethrough`, `RichTextSpoiler`, and structural types for headings, lists, tables, etc.

## Relevance to clawd

- `sendRichMessageDraft` + LLM SSE streaming = structured document streamed token-by-token — ideal fit.
- `ClawTelegram` already abstracts the Bot API behind `TelegramTransport`; adding these endpoints is additive.
- `MarkdownEscaper` would be replaced or supplemented by a Markdown → `MessageEntity` converter.
- `ReplySplitter` may become unnecessary for rich messages (no length cap on rich bodies, pending confirmation).
- Known issue (as of launch): `editMessageText` with `rich_message` destroys formatting mid-stream — tracked upstream ([hermes-agent #46009](https://github.com/NousResearch/hermes-agent/issues/46009)).

## Sources

- [Telegram Desktop 6.9 announcement](https://www.techtimes.com/articles/318257/20260611/telegram-desktop-69-bots-get-document-grade-formatting-guardian-controls-streaming.htm)
- [Bot API changelog](https://core.telegram.org/bots/api-changelog)
- [hermes-agent: Feature support Bot API 10.1](https://github.com/NousResearch/hermes-agent/issues/45864)
- [hermes-agent: Rich message streaming bug](https://github.com/NousResearch/hermes-agent/issues/46009)
