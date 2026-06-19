# Telegram Bot API — Rich Messages Primary Reference

**Source:** https://core.telegram.org/bots/api  
**Changelog source:** https://core.telegram.org/bots/api-changelog  
**Retrieved:** 2026-06-19 via Playwright browser (rendered HTML)  
**Method:** DOM extraction using `document.getElementById(anchor).innerText` per section

---

## Bot API 10.1 Changelog (June 11, 2026) — Verbatim

From https://core.telegram.org/bots/api-changelog, under heading "2026 → June 11, 2026 → Bot API 10.1":

**Rich Messages section:**

> Added support for Rich Messages, allowing bots to send highly structured text and stream AI-generated replies with seamless rich formatting.
>
> Added the classes RichTextBold, RichTextItalic, RichTextUnderline, RichTextStrikethrough, RichTextSpoiler, RichTextDateTime, RichTextTextMention, RichTextSubscript, RichTextSuperscript, RichTextMarked, RichTextCode, RichTextCustomEmoji, RichTextMathematicalExpression, RichTextUrl, RichTextEmailAddress, RichTextPhoneNumber, RichTextBankCardNumber, RichTextMention, RichTextHashtag, RichTextCashtag, RichTextBotCommand, RichTextAnchor, RichTextAnchorLink, RichTextReference and RichTextReferenceLink, which represent different types of rich formatted text.
>
> Added the class RichText, which represents rich formatted text.
>
> Added the class RichBlockCaption, which represents the caption of a rich formatted text.
>
> Added the class RichBlockTableCell, which represents a cell in a table.
>
> Added the class RichBlockListItem, which represents an item in a list.
>
> Added the classes RichBlockParagraph, RichBlockSectionHeading, RichBlockPreformatted, RichBlockFooter, RichBlockDivider, RichBlockMathematicalExpression, RichBlockAnchor, RichBlockList, RichBlockBlockQuotation, RichBlockPullQuotation, RichBlockCollage, RichBlockSlideshow, RichBlockTable, RichBlockDetails, RichBlockMap, RichBlockAnimation, RichBlockAudio, RichBlockPhoto, RichBlockVideo, RichBlockVoiceNote and RichBlockThinking, which represent different types of blocks in a rich formatted message.
>
> Added the class RichBlock, which represents a block in a rich formatted message.
>
> Added the class RichMessage, which represents a rich formatted message.
>
> Added the field rich_message to the class Message.
>
> Added the class InputRichMessage, describing a rich message to send.
>
> Added the class InputRichMessageContent and allowed it to be used as InputMessageContent in results of inline, guest, and Web App queries.
>
> Added the method sendRichMessage, allowing bots to send rich messages.
>
> Added the method sendRichMessageDraft, allowing bots to stream partial rich messages.
>
> Added the parameter rich_message to the method editMessageText, allowing bots to edit rich messages.

---

## DEFINITIVE ANSWER: Markdown/HTML String vs. Block Tree

**A bot passes a markdown or HTML string. No client-side block-tree construction is required for sending.**

From the `InputRichMessage` definition (verbatim):

> "Describes a rich message to be sent. Exactly **one** of the fields *html* or *markdown* must be used."

The two input fields are both plain strings (`String` type). The block-tree types (`RichBlock*`, `RichText*`, `RichMessage`) are only present in **received** `Message` objects (the `rich_message` field) — they are what the server returns after parsing your input string. There is no `InputRichBlock` or similar type for bots to construct.

---

## Methods

### sendRichMessage

**Description:** Use this method to send rich messages. If the message contains a block with a media element, then the bot must have the right to send the media to the chat. On success, the sent [Message](https://core.telegram.org/bots/api#message) is returned.

**Return type:** `Message`

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| business_connection_id | String | Optional | Unique identifier of the business connection on behalf of which the message will be sent. Bot can send rich messages on behalf of a business account only if the corresponding user can send rich messages. |
| chat_id | Integer or String | **Yes** | Unique identifier for the target chat or username of the target bot, supergroup or channel in the format `@username` |
| message_thread_id | Integer | Optional | Unique identifier for the target message thread (topic) of a forum; for forum supergroups and private chats of bots with forum topic mode enabled only |
| direct_messages_topic_id | Integer | Optional | Identifier of the direct messages topic to which the message will be sent; required if the message is sent to a direct messages chat |
| rich_message | InputRichMessage | **Yes** | The message to be sent |
| disable_notification | Boolean | Optional | Sends the message silently. Users will receive a notification with no sound. |
| protect_content | Boolean | Optional | Protects the contents of the sent message from forwarding and saving |
| allow_paid_broadcast | Boolean | Optional | Pass *True* to allow up to 1000 messages per second, ignoring broadcasting limits for a fee of 0.1 Telegram Stars per message. The relevant Stars will be withdrawn from the bot's balance. |
| message_effect_id | String | Optional | Unique identifier of the message effect to be added to the message; for private chats only |
| suggested_post_parameters | SuggestedPostParameters | Optional | A JSON-serialized object containing the parameters of the suggested post to send; for direct messages chats only. If the message is sent as a reply to another suggested post, then that suggested post is automatically declined. |
| reply_parameters | ReplyParameters | Optional | Description of the message to reply to |
| reply_markup | InlineKeyboardMarkup or ReplyKeyboardMarkup or ReplyKeyboardRemove or ForceReply | Optional | Additional interface options. A JSON-serialized object for an inline keyboard, custom reply keyboard, instructions to remove a reply keyboard or to force a reply from the user. |

**Note:** The docs do NOT state `sendRichMessage` is private-chat-only. It accepts groups, supergroups, and channels via `chat_id`.

---

### sendRichMessageDraft

**Description:** Use this method to stream a partial rich message to a user while the message is being generated. Note that the streamed draft is ephemeral and acts as a temporary 30-second preview — once the output is finalized, you **must** call [sendRichMessage](https://core.telegram.org/bots/api#sendrichmessage) with the complete message to persist it in the user's chat. Returns *True* on success.

**Return type:** `True`

**Private-chat only:** Yes — `chat_id` is typed `Integer` (not `Integer or String`), and its description reads "Unique identifier for the target **private chat**".

**Draft lifetime:** 30 seconds (verbatim: "ephemeral and acts as a temporary 30-second preview").

**Finalization requirement:** Yes — "once the output is finalized, you **must** call sendRichMessage with the complete message to persist it".

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| chat_id | Integer | **Yes** | Unique identifier for the target private chat |
| message_thread_id | Integer | Optional | Unique identifier for the target message thread |
| draft_id | Integer | **Yes** | Unique identifier of the message draft; must be non-zero. Changes to drafts with the same identifier are animated. |
| rich_message | InputRichMessage | **Yes** | The partial message to be streamed |

---

### editMessageText

**Description:** Use this method to edit text, rich and [game](https://core.telegram.org/bots/api#games) messages. On success, if the edited message is not an inline message, the edited [Message](https://core.telegram.org/bots/api#message) is returned, otherwise *True* is returned. Note that business messages that were not sent by the bot and do not contain an inline keyboard can only be edited within **48 hours** from the time they were sent.

**Return type:** `Message` or `True`

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| business_connection_id | String | Optional | Unique identifier of the business connection on behalf of which the message to be edited was sent |
| chat_id | Integer or String | Optional | Required if *inline_message_id* is not specified. Unique identifier for the target chat or username of the target bot, supergroup or channel in the format `@username`. |
| message_id | Integer | Optional | Required if *inline_message_id* is not specified. Identifier of the message to edit. |
| inline_message_id | String | Optional | Required if *chat_id* and *message_id* are not specified. Identifier of the inline message. |
| text | String | Optional | New text of the message, 1-4096 characters after entity parsing; required if *rich_message* isn't specified |
| parse_mode | String | Optional | Mode for parsing entities in the message text. See formatting options for more details. |
| entities | Array of MessageEntity | Optional | A JSON-serialized list of special entities that appear in message text, which can be specified instead of *parse_mode* |
| link_preview_options | LinkPreviewOptions | Optional | Link preview generation options for the message |
| **rich_message** | **InputRichMessage** | **Optional** | **New rich content of the message; required if *text* isn't specified** |
| reply_markup | InlineKeyboardMarkup | Optional | A JSON-serialized object for an inline keyboard |

---

## Types for Sending

### InputRichMessage

**Description (verbatim):** Describes a rich message to be sent. Exactly **one** of the fields *html* or *markdown* must be used.

| Field | Type | Description |
|-------|------|-------------|
| html | String | *Optional.* Content of the rich message to send described using HTML formatting. See rich message formatting options for more details. |
| markdown | String | *Optional.* Content of the rich message to send described using Markdown formatting. See rich message formatting options for more details. |
| is_rtl | Boolean | *Optional.* Pass *True* if the rich message must be shown right-to-left |
| skip_entity_detection | Boolean | *Optional.* Pass *True* to skip automatic detection of entities (e.g., URLs, email addresses, username mentions, hashtags, cashtags, bot commands, or phone numbers) in the text |

**Note:** "Exactly one of html or markdown must be used" — these are mutually exclusive. Both are Optional in the table but the prose makes exactly one required.

---

### InputRichMessageContent

**Description:** Represents the content of a rich message to be sent as the result of an inline query.

| Field | Type | Description |
|-------|------|-------------|
| rich_message | InputRichMessage | The message to be sent |

Used as `InputMessageContent` in results of inline, guest, and Web App queries.

---

## Types in Received Messages (Read-Only)

These types appear in the `rich_message` field of the received `Message` object. They are **not** needed for sending; they represent the server-parsed block tree returned to the bot.

### RichMessage

**Description:** Rich formatted message.

| Field | Type | Description |
|-------|------|-------------|
| blocks | Array of RichBlock | Content of the message |
| is_rtl | Boolean | *Optional.* True, if the rich message must be shown right-to-left |

**In Message object:** `rich_message` field — `Optional. Message is a rich formatted message`. The `text` field on `Message` is a separate Optional field ("For text messages, the actual UTF-8 text of the message"). The docs do **not** state that a `text` fallback is populated for rich messages — no backward-compat note was found on the page for this.

---

### RichBlock (union)

**Description:** This object represents a block in a rich formatted message. Currently, it can be any of the following types:

RichBlockParagraph, RichBlockSectionHeading, RichBlockPreformatted, RichBlockFooter, RichBlockDivider, RichBlockMathematicalExpression, RichBlockAnchor, RichBlockList, RichBlockBlockQuotation, RichBlockPullQuotation, RichBlockCollage, RichBlockSlideshow, RichBlockTable, RichBlockDetails, RichBlockMap, RichBlockAnimation, RichBlockAudio, RichBlockPhoto, RichBlockVideo, RichBlockVoiceNote, RichBlockThinking

---

### RichBlockParagraph

A text paragraph, corresponding to the HTML tag `<p>`.

| Field | Type | Description |
|-------|------|-------------|
| type | String | Type of the block, always "paragraph" |
| text | RichText | Text of the block |

---

### RichBlockSectionHeading

A section heading, corresponding to the HTML tags `<h1>`, `<h2>`, `<h3>`, `<h4>`, `<h5>`, or `<h6>`.

| Field | Type | Description |
|-------|------|-------------|
| type | String | Type of the block, always "heading" |
| text | RichText | Text of the block |
| size | Integer | Relative size of the text font; 1-6, 1 is the largest, 6 is the smallest |

---

### RichBlockPreformatted

A preformatted text block, corresponding to the nested HTML tags `<pre>` and `<code>`.

| Field | Type | Description |
|-------|------|-------------|
| type | String | Type of the block, always "pre" |
| text | RichText | Text of the block |
| language | String | *Optional.* The programming language of the text |

---

### RichBlockFooter

A footer, corresponding to the HTML tag `<footer>`.

| Field | Type | Description |
|-------|------|-------------|
| type | String | Type of the block, always "footer" |
| text | RichText | Text of the block |

---

### RichBlockDivider

A divider, corresponding to the HTML tag `<hr/>`.

| Field | Type | Description |
|-------|------|-------------|
| type | String | Type of the block, always "divider" |

---

### RichBlockMathematicalExpression

A block with a mathematical expression in LaTeX format, corresponding to the custom HTML tag `<tg-math-block>`.

| Field | Type | Description |
|-------|------|-------------|
| type | String | Type of the block, always "mathematical_expression" |
| expression | String | The mathematical expression in LaTeX format |

---

### RichBlockAnchor

A block with an anchor, corresponding to the HTML tag `<a>` with the attribute `name`.

| Field | Type | Description |
|-------|------|-------------|
| type | String | Type of the block, always "anchor" |
| name | String | The name of the anchor |

---

### RichBlockList

A list of blocks, corresponding to the HTML tag `<ul>` or `<ol>` with multiple nested tags `<li>`.

| Field | Type | Description |
|-------|------|-------------|
| type | String | Type of the block, always "list" |
| items | Array of RichBlockListItem | Items of the list |

---

### RichBlockListItem

An item of a list.

| Field | Type | Description |
|-------|------|-------------|
| label | String | Label of the item |
| blocks | Array of RichBlock | The content of the item |
| has_checkbox | True | *Optional.* True, if the item has a checkbox |
| is_checked | True | *Optional.* True, if the item has a checked checkbox |
| value | Integer | *Optional.* For ordered lists, the numeric value of the item label |
| type | String | *Optional.* For ordered lists, the type of the item label; must be one of "a" for lowercase letters, "A" for uppercase letters, "i" for lowercase Roman numerals, "I" for uppercase Roman numerals, or "1" for decimal numbers |

---

### RichBlockBlockQuotation

A block quotation, corresponding to the HTML tag `<blockquote>`.

| Field | Type | Description |
|-------|------|-------------|
| type | String | Type of the block, always "blockquote" |
| blocks | Array of RichBlock | Content of the block |
| credit | RichText | *Optional.* Credit of the block |

---

### RichBlockPullQuotation

A quotation with centered text, loosely corresponding to the HTML tag `<aside>`.

| Field | Type | Description |
|-------|------|-------------|
| type | String | Type of the block, always "pullquote" |
| text | RichText | Text of the block |
| credit | RichText | *Optional.* Credit of the block |

---

### RichBlockCollage

A collage, corresponding to the custom HTML tag `<tg-collage>`.

| Field | Type | Description |
|-------|------|-------------|
| type | String | Type of the block, always "collage" |
| blocks | Array of RichBlock | Elements of the collage |
| caption | RichBlockCaption | *Optional.* Caption of the block |

---

### RichBlockSlideshow

A slideshow, corresponding to the custom HTML tag `<tg-slideshow>`.

| Field | Type | Description |
|-------|------|-------------|
| type | String | Type of the block, always "slideshow" |
| blocks | Array of RichBlock | Elements of the slideshow |
| caption | RichBlockCaption | *Optional.* Caption of the block |

---

### RichBlockTable

A table, corresponding to the HTML tag `<table>`.

| Field | Type | Description |
|-------|------|-------------|
| type | String | Type of the block, always "table" |
| cells | Array of Array of RichBlockTableCell | Cells of the table |
| is_bordered | True | *Optional.* True, if the table has borders |
| is_striped | True | *Optional.* True, if the table is striped |
| caption | RichText | *Optional.* Caption of the table |

---

### RichBlockTableCell

Cell in a table.

| Field | Type | Description |
|-------|------|-------------|
| text | RichText | *Optional.* Text in the cell. If omitted, then the cell is invisible. |
| is_header | True | *Optional.* True, if the cell is a header cell |
| colspan | Integer | *Optional.* The number of columns the cell spans if it is bigger than 1 |
| rowspan | Integer | *Optional.* The number of rows the cell spans if it is bigger than 1 |
| align | String | Horizontal cell content alignment. Currently, must be one of "left", "center", or "right". |
| valign | String | Vertical cell content alignment. Currently, must be one of "top", "middle", or "bottom". |

---

### RichBlockDetails

An expandable block for details disclosure, corresponding to the HTML tag `<details>`.

| Field | Type | Description |
|-------|------|-------------|
| type | String | Type of the block, always "details" |
| summary | RichText | Always shown summary of the block |
| blocks | Array of RichBlock | Content of the block |
| is_open | True | *Optional.* True, if the content of the block is visible by default |

---

### RichBlockMap

A block with a map, corresponding to the custom HTML tag `<tg-map>`.

| Field | Type | Description |
|-------|------|-------------|
| type | String | Type of the block, always "map" |
| location | Location | Location of the center of the map |
| zoom | Integer | Map zoom level; 13-20 |
| width | Integer | Expected width of the map |
| height | Integer | Expected height of the map |
| caption | RichBlockCaption | *Optional.* Caption of the block |

---

### RichBlockAnimation

A block with an animation, corresponding to the HTML tag `<video>`.

| Field | Type | Description |
|-------|------|-------------|
| type | String | Type of the block, always "animation" |
| animation | Animation | The animation |
| has_spoiler | True | *Optional.* True, if the media preview is covered by a spoiler animation |
| caption | RichBlockCaption | *Optional.* Caption of the block |

---

### RichBlockAudio

A block with a music file, corresponding to the HTML tag `<audio>`.

| Field | Type | Description |
|-------|------|-------------|
| type | String | Type of the block, always "audio" |
| audio | Audio | The audio |
| caption | RichBlockCaption | *Optional.* Caption of the block |

---

### RichBlockPhoto

A block with a photo, corresponding to the HTML tag `<img>`.

| Field | Type | Description |
|-------|------|-------------|
| type | String | Type of the block, always "photo" |
| photo | Array of PhotoSize | Available sizes of the photo |
| has_spoiler | True | *Optional.* True, if the media preview is covered by a spoiler animation |
| caption | RichBlockCaption | *Optional.* Caption of the block |

---

### RichBlockVideo

A block with a video, corresponding to the HTML tag `<video>`.

| Field | Type | Description |
|-------|------|-------------|
| type | String | Type of the block, always "video" |
| video | Video | The video |
| has_spoiler | True | *Optional.* True, if the media preview is covered by a spoiler animation |
| caption | RichBlockCaption | *Optional.* Caption of the block |

---

### RichBlockVoiceNote

A block with a voice note, corresponding to the HTML tag `<audio>`.

| Field | Type | Description |
|-------|------|-------------|
| type | String | Type of the block, always "voice_note" |
| voice_note | Voice | The voice note |
| caption | RichBlockCaption | *Optional.* Caption of the block |

---

### RichBlockThinking

A block with a "Thinking…" placeholder, corresponding to the custom HTML tag `<tg-thinking>`. The block **may be used only in sendRichMessageDraft**, therefore it **can't be received in messages**. See https://t.me/addemoji/AIActions for examples of custom emoji, which are recommended for usage in the block.

| Field | Type | Description |
|-------|------|-------------|
| type | String | Type of the block, always "thinking" |
| text | RichText | Text of the block |

---

### RichBlockCaption

Caption of a rich formatted block.

| Field | Type | Description |
|-------|------|-------------|
| text | RichText | Block caption |
| credit | RichText | *Optional.* Block credit which corresponds to the HTML tag `<cite>` |

---

### RichText (union)

**Description:** This object represents a rich formatted text. Currently, it can be either a **String** for plain text, an **Array of RichText**, or any of the following types:

RichTextBold, RichTextItalic, RichTextUnderline, RichTextStrikethrough, RichTextSpoiler, RichTextDateTime, RichTextTextMention, RichTextSubscript, RichTextSuperscript, RichTextMarked, RichTextCode, RichTextCustomEmoji, RichTextMathematicalExpression, RichTextUrl, RichTextEmailAddress, RichTextPhoneNumber, RichTextBankCardNumber, RichTextMention, RichTextHashtag, RichTextCashtag, RichTextBotCommand, RichTextAnchor, RichTextAnchorLink, RichTextReference, RichTextReferenceLink

---

### RichText Leaf Types

All leaf types share a `type` discriminator string.

| Type | type value | Fields |
|------|-----------|--------|
| RichTextBold | "bold" | text: RichText |
| RichTextItalic | "italic" | text: RichText |
| RichTextUnderline | "underline" | text: RichText |
| RichTextStrikethrough | "strikethrough" | text: RichText |
| RichTextSpoiler | "spoiler" | text: RichText |
| RichTextSubscript | "subscript" | text: RichText |
| RichTextSuperscript | "superscript" | text: RichText |
| RichTextMarked | "marked" | text: RichText |
| RichTextCode | "code" | text: RichText |
| RichTextDateTime | "date_time" | text: RichText, unix_time: Integer, date_time_format: String |
| RichTextTextMention | "text_mention" | text: RichText, user: User |
| RichTextCustomEmoji | "custom_emoji" | custom_emoji_id: String, alternative_text: String |
| RichTextMathematicalExpression | "mathematical_expression" | expression: String |
| RichTextUrl | "url" | text: RichText, url: String |
| RichTextEmailAddress | "email_address" | text: RichText, email_address: String |
| RichTextPhoneNumber | "phone_number" | text: RichText, phone_number: String |
| RichTextBankCardNumber | "bank_card_number" | text: RichText, bank_card_number: String |
| RichTextMention | "mention" | text: RichText, username: String |
| RichTextHashtag | "hashtag" | text: RichText, hashtag: String |
| RichTextCashtag | "cashtag" | text: RichText, cashtag: String |
| RichTextBotCommand | "bot_command" | text: RichText, bot_command: String |
| RichTextAnchor | "anchor" | name: String |
| RichTextAnchorLink | "anchor_link" | text: RichText, anchor_name: String (empty = top of message) |
| RichTextReference | "reference" | text: RichText, name: String |
| RichTextReferenceLink | "reference_link" | text: RichText, reference_name: String |

---

## MessageEntity Types (all, including new in 10.1)

From the `MessageEntity` definition on the page (verbatim excerpt):

> Type of the entity. Currently, can be "mention" (@username), "hashtag" (#hashtag or #hashtag@chatusername), "cashtag" ($USD or $USD@chatusername), "bot_command" (/start@jobs_bot), "url" (https://telegram.org), "email" (do-not-reply@telegram.org), "phone_number" (+1-212-555-0123), "bold" (bold text), "italic" (italic text), "underline" (underlined text), "strikethrough" (strikethrough text), "spoiler" (spoiler message), "blockquote" (block quotation), "expandable_blockquote" (collapsed-by-default block quotation), "code" (monowidth string), "pre" (monowidth block), "text_link" (for clickable text URLs), "text_mention" (for users without usernames), "custom_emoji" (for inline custom emoji stickers), or **"date_time"** (for formatted date and time).

**New in 10.1:** `"date_time"` — for formatted date and time.

**Pre-existing types also noted:** `"blockquote"` and `"expandable_blockquote"` were already present before 10.1 (per the existing MarkdownV2 docs). The changelog does **not** list them as newly added in 10.1.

**Entity offset encoding:** Confirmed UTF-16 code units — `offset: Integer` — "Offset in UTF-16 code units to the start of the entity" and `length: Integer` — "Length of the entity in UTF-16 code units".

**MessageEntity fields for `date_time` type:**
- `unix_time`: Integer — *Optional.* For "date_time" only, the Unix time associated with the entity
- `date_time_format`: String — *Optional.* For "date_time" only, the string that defines the formatting of the date and time.

---

## Limits

From the "Rich Message Formatting Options → Rich Message Limits" section (verbatim):

> Rich messages are subject to the following limits:
>
> - Up to **32768 UTF-8 characters** in the rich message text, including custom emoji alternative text and formula source.
> - Up to **500 blocks**, including nested blocks, list items, ordered list items, table rows, quotation blocks, and details blocks.
> - Up to **16 levels** of nested formatting and blocks.
> - Up to **50 media attachments** in total, including photos, videos, and audio files.
> - Up to **20 columns** in a table.

| Limit | Value |
|-------|-------|
| Max content characters | 32,768 UTF-8 characters |
| Max blocks (including nested) | 500 |
| Max nesting depth | 16 levels |
| Max media attachments | 50 (photos + videos + audio) |
| Max table columns | 20 |
| Draft lifetime | 30 seconds |
| Draft scope | Private chats only |

**Rate limits:** No specific rate limit for `sendRichMessage` / `sendRichMessageDraft` was found on the page beyond the general `allow_paid_broadcast` note (1000 msg/s with fee).

**Backward compatibility / text fallback for old clients:** The page does **not** state that a plain `text` field is populated in the `Message` object for rich messages received by old clients. The `text` field on `Message` is described as "For text messages, the actual UTF-8 text of the message" — separate from `rich_message`. No explicit backward-compat note was found.

---

## Rich Message Formatting Options Summary

### Rich Markdown Style (pass in `markdown` field)

Key syntax (verbatim from page):

```
**bold text**  or  __bold text__
*italic text*  or  _italic text_
~~strikethrough text~~
`inline fixed-width code`
==marked text==
||spoiler||

[inline URL](https://t.me/)
[inline e-mail](mailto:user@example.com)
[inline phone number](tel:+123456789)
[inline mention of a user](tg://user?id=123456789)
![](tg://emoji?id=5368324170671202286)
![22:45 tomorrow](tg://time?unix=1647531900&format=wDT)
$x^2 + y^2$

# Heading 1  through  ###### Heading 6

Paragraph text (blank line = paragraph break)

```python
code block
```

---   (divider)

- unordered list item  /  * unordered list item  /  + unordered list item
1. ordered list item

- [ ] task list item
- [x] completed task list item

>Block quotation (> prefix lines)

![](https://telegram.org/example/photo.jpg)   (media blocks, HTTP/HTTPS only)

| Header 1 | Header 2 |
|:---------|:--------:|
| left     | center   |

Text with a reference[^id1] and another[^id2].
[^id1]: Definition of the first footnote.

$$E = mc^2$$    or    ```math ... ```    (block math)

<tg-collage>...</tg-collage>
<tg-slideshow>...</tg-slideshow>
<details open><summary>Title</summary>Content</details>
```

Additionally usable in `sendRichMessageDraft` only:
```
<tg-thinking>Thinking...</tg-thinking>
```

### Rich HTML Style (pass in `html` field)

All standard tags: `<b>`, `<i>`, `<u>`, `<s>`, `<code>`, `<pre>`, `<mark>`, `<sub>`, `<sup>`, `<tg-spoiler>`, `<a>`, `<h1>`–`<h6>`, `<p>`, `<footer>`, `<hr/>`, `<ul>`, `<ol>`, `<li>`, `<blockquote>`, `<aside>`, `<img>`, `<video>`, `<audio>`, `<figure>`, `<figcaption>`, `<cite>`, `<table>`, `<tr>`, `<td>`, `<th>`, `<caption>`, `<details>`, `<summary>`, `<tg-collage>`, `<tg-slideshow>`, `<tg-map>`, `<tg-math-block>`, `<tg-emoji>`, `<tg-time>`, `<tg-reference>`, `<tg-math>`.

Draft-only: `<tg-thinking>`.

Named HTML entities supported: `&lt;`, `&gt;`, `&amp;`, `&quot;`, `&apos;`, `&nbsp;`, `&hellip;`, `&mdash;`, `&ndash;`, `&lsquo;`, `&rsquo;`, `&ldquo;`, `&rdquo;`.

---

## Date-Time Entity Formatting

Format string regex: `r|w?[dD]?[tT]?`

| Character | Meaning |
|-----------|---------|
| r | Relative time. Cannot combine with others. |
| w | Day of the week (localized) |
| d | Date in short form (e.g., "17.03.22") |
| D | Date in long form (e.g., "March 17, 2022") |
| t | Time in short form (e.g., "22:45") |
| T | Time in long form (e.g., "22:45:00") |

Empty format string = display as-is; user can still see date in local format.

---

## What Was NOT Found on the Page

1. **No backward-compat note** stating whether `text` is populated on the `Message` object when `rich_message` is set (i.e., whether old clients see a plain-text fallback). The `text` and `rich_message` fields are documented as separate optional fields on `Message`.
2. **No explicit per-method rate limit** for `sendRichMessage` or `sendRichMessageDraft` beyond the general broadcasting note.
3. **No `InputRichBlock`** or similar — there is no structured block-tree type for sending. Sending uses only `InputRichMessage` (markdown or html string).
4. The changelog does not mention `blockquote` or `expandable_blockquote` as new in 10.1 — those were pre-existing MessageEntity types.
5. No explicit note about `RichBlockThinking` not appearing in the `Message.rich_message` block tree when received — however, the type definition states: "The block may be used only in sendRichMessageDraft, therefore it can't be received in messages."
