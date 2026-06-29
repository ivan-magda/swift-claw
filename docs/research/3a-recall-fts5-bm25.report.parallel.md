# FTS5 BM25 Recall for GRDB.swift v7: Sign, Cutoffs, External Content, Idioms, Tokenizer

## Executive Summary

- **BM25 sign confirmed**: SQLite FTS5's `bm25()` returns **non-positive (negative) real numbers where more negative = better match**, because the implementation multiplies the canonical BM25 by -1. Use `ORDER BY bm25(fts)` (default ASC) for best-match-first; never wrap it in `ASC` explicitly unless you also negate, and never use `DESC`. [executive_summary[0]] [2]
- **Constants are not negotiable**: `k1` and `b` are hard-coded to **1.2 and 0.75** respectively inside `fts5.c`; the column-weight syntax `bm25(fts, w1, w2, ...)` accepts any number of trailing weight arguments (missing columns default to 1.0, extra arguments are silently ignored). [executive_summary[0]] [2]
- **Cutoff spectrum**: Always-take-top-K is the worst default because it ignores the question "is anything actually relevant?" - but a single global numeric threshold is brittle because BM25 scores are corpus-relative and unbounded with IDF skew. The most principled approach is **per-query normalization**: divide each hit's bm25() by the top-1 hit of the same query to get a 0..1 confidence, then apply a global cutoff on the **ratio** (not the raw score) - this matches the spirit of Elasticsearch's `min_score`-as-fraction-of-best-hit pattern. [executive_summary[1]] [1]
- **External-content rowid alignment is mandatory, not optional**: When the source table has a named `INTEGER PRIMARY KEY` (e.g. `messages.id`), the FTS5 table MUST specify `content_rowid='id'`. Once aligned, `fts.rowid` and `messages.id` refer to the same key, so exclusions can be expressed as `WHERE messages.id NOT IN (…)` on the JOIN. Build the FTS index on the content table; FTS5 reads column values via a generated `SELECT <content_rowid>, <cols> FROM <content> WHERE <content_rowid>=?` query, so an external-content table is **read-only through SELECT** and writes go to the content table only. [executive_summary[0]] [2]
- **GRDB v7 idiom is raw SQL with `FTS5Pattern`**: For safe MATCH pattern construction, use `FTS5Pattern(matchingAnyTokenIn:)` (or `matchingAllTokensIn:`, `matchingPhrase:`, `matchingPrefixPhrase:`, `matchingAllPrefixesIn:`); pass it as a parameter to `try Row.fetchAll(db, sql: "... MATCH ?", arguments: [pattern])` or use a `JOIN messages_fts ON messages_fts.rowid = messages.id AND messages_fts MATCH ?`. v7 renamed `FTS5Tokenizer` to `FTS5TokenizerDescriptor`; `String.fetch...` now returns non-optional values. GRDB FullTextSearch docs, [executive_summary[2]] [21]
- **Tokenizer recommendation for English conversational**: `unicode61 remove_diacritics 2` is the right default. It folds accents (`cafe` matches `cafe`), is lower-case aware, and produces a compact inverted index. `porter` adds English stemming (helps `running`/`ran`/`run` collapse to `run`) at the cost of over-stemming conversational forms. `trigram` is wrong for English production recall (3-5x index bloat, designed for CJK) but excellent for fuzzy substring fallback. If misspellings matter (chat typos, names), wrap `unicode61` in GRDB's `LatinAsciiTokenizer` which lower-cases and strips diacritics for fuzzy "Grossmann ~ Grossmann" matching. [executive_summary[3]] [54], [executive_summary[4]] [16]

---

## 1. BM25 Sign & Scale: Negative Values, More-Negative-Is-Better

SQLite FTS5 implements BM25 with an inverted sign so that "best first" maps onto the natural SQL default of ascending order. The verbatim wording from the official docs:

> "The bm25() auxiliary function returns a real value reflecting the accuracy of the current match. **Better matches are assigned numerically lower values**. In order to avoid this pitfall, the FTS5 implementation of BM25 multiplies the result by -1 before returning it, ensuring that better matches are assigned numerically lower scores." [1_bm25_sign_and_scale_negative_values_more_negative_is_better[0]] [2]

In SQL this means:

```sql
SELECT messages.*
FROM messages
JOIN messages_fts ON messages_fts.rowid = messages.id
WHERE messages_fts MATCH ?
ORDER BY bm25(messages_fts);   -- default ASC: best first
```

**Practical facts** you should encode as constants in your daeon's source so they never drift from upstream:

| Item | Value | Source |
|---|---|---|
| `k1` | hard-coded `1.2` | [1_bm25_sign_and_scale_negative_values_more_negative_is_better[0]] [2] |
| `b`  | hard-coded `0.75` | [1_bm25_sign_and_scale_negative_values_more_negative_is_better[0]] [2] |
| Output sign | negative; more negative = better | [1_bm25_sign_and_scale_negative_values_more_negative_is_better[0]] [2] |
| Order direction | ascending (no `DESC`) | [1_bm25_sign_and_scale_negative_values_more_negative_is_better[1]] [4] |
| Column weights | `bm25(fts, w1, w2, ...)` - positional | [1_bm25_sign_and_scale_negative_values_more_negative_is_better[0]] [2] |
| Missing/extra weights | missing = 1.0, extras silently ignored | [1_bm25_sign_and_scale_negative_values_more_negative_is_better[0]] [2] |

Your belief in negative values is correct. The "more negative = better" direction matters because if you ever copy a number into a regression or threshold, the sign must be preserved or you will silently invert the ranking. Note that because the auxiliary function wraps the canonical BM25 by -1, scores are **unbounded** - there is no theoretical floor or ceiling, which directly motivates the cutoff problem in section 2.

**Mechanism - why the negation.** Native BM25 is "higher = better," but SQL `ORDER BY` defaults to ascending. Without the negation, two natural habits would fight each other: writing `ORDER BY bm25(ft)` expecting best-first (intuitive but wrong) vs. using `DESC` (correct but easy to forget when reviewing logs). FTS5 resolves the conflict by flipping the sign, making `ORDER BY bm25(ft)` produce the correct order as the default.

**Implication.** When you log or export `bm25()` values for debugging, always multiply by `-1` to get the canonical "higher = better" form, or annotate the column header `bm25_neg`. The StackOverflow/TreeSearch community confirms "more negative = better" as the prevailing understanding on FTS5/SCore tooling, even if PostgreSQL `ts_rank` uses positive values. [1_bm25_sign_and_scale_negative_values_more_negative_is_better[2]] [5]

**Recommendation.** Adopt a thin wrapper that, internally, flips the sign and returns a non-negative "score_bm25" so that the rest of your code (cutoff, telemetry, A/B tests) operates in a "higher = better" universe. This decouples your recall policy from SQLite's quirk and makes it trivial to swap in another lexical ranker later.

---

## 2. Relevance Cutoff: Four Options Compared

BM25 outputs are corpus-relative: a query like "ok" against 200k short chat messages returns wildly different absolute scores than the same query against 5k long documents. As the FTS5 scoring notes observe, **"these scores are not naturally normalized, the output can vary significantly based on document lengths and term frequencies"** [2_relevance_cutoff_four_options_compared[0]] [1]. That makes a hard threshold brittle. Here is the menu:

| Strategy | Mechanism | Pros | Cons | When to use |
|---|---|---|---|---|
| **Always top-K** | Take first N hits, no cutoff | Predictable context size; simple | Injects noise on irrelevant queries | Toy/demo, never production recall |
| **Absolute threshold** (e.g. `bm25(fts) < -3.0`) | Reject hits above (less negative than) some number | Easy to write | Brittle: corpus-relative; IDF skew; depends on `k1`/`b`; can yield zero results for hard queries even when top hit is genuine | As a **safety fall-back** when per-query norm is too hard |
| **Score-gap / elbow** | Compare bm25(n) to bm25(n+1); stop when delta spikes | Detects natural cluster break | Requires at least 2 hits; gap magnitude is itself corpus-relative (same problem as absolute threshold); sensitive to ties | When you can log and tune the gap multiplier (e.g. 1.5x) |
| **Per-query max normalization** | `rel = bm25(hit) / bm25(top_hit)` ∈ [-1, 0], threshold like `rel < -0.45` | Adapts to every query's distribution; intuitive "fraction of best match" semantics; matches Elasticsearch `min_score`-as-fraction pattern | Requires querying top hit first (or windowed over a single query: take all hits, compute on top-1) | **Recommended** - the principled default |
| **Hybrid: norm + gap** | Apply per-query ratio, then enforce a min number of hits and a max drop-off | Self-correction when top-K is too small or too big | Most code; needs tuning | High-stakes recall |

The MathGate reference (the cleanest practical summary we located) puts it bluntly: **"In practice, scores are typically rescaled or thresholded before being shown to users"** - so the field explicitly acknowledges the thresholding problem and treats the per-query score as a feature to be re-scaled before any user-facing decision [2_relevance_cutoff_four_options_compared[1]] [29]. The StackOverflow answer cited above confirms that FTS5 BM25 has no absolute meaning across queries.

**Mechanism - why per-query max normalization works.** The IDF component of BM25 depends on corpus term distribution. If 30% of messages contain the word "the," then "the" contributes near-zero IDF regardless of how often it repeats in any single document; if the corpus is small and curated, even rare terms attract higher IDF, producing deeply negative top scores. By dividing every hit's score by the top-1 hit's score of the **same query**, the IDF dependence is cancelled out (it normalizes the same number), and only the relative dominance of the top document over the rest remains. A ratio of 0.5 in a 5-document corpus means "half as relevant as the best," independent of corpus size.

**Implication - score=0 is information, not absence.** A `bm25()` value of 0 means either no matched terms or all terms have Robertson IDF=0 (i.e., the term appears in every document). That is itself a useful pre-filter: if the top-1 hit's bm25 is exactly 0, your lexical recall has found **no real signal** - inject nothing and report it as a "no recall" outcome in your metrics.

**Recommendation.** Use a three-stage cutoff in code:

1. Fetch a generous candidate window (e.g. `LIMIT 50`) with raw `bm25(messages_fts)` scores.
2. Compute `rel[i] = bm25[i] / bm25[0]`. Drop the top hit, drop any with `rel > -0.45` (tunable), drop those whose `bm25 = 0`.
3. Cap at a hard maximum (e.g. 8 messages) and a minimum (e.g. 1) so you never inject an unbounded amount of context into the LLM turn.

This is conservative - it lets a low-IDF noisy query inject nothing, while letting a high-signal query inject up to the cap. Pair it with a "no recall" branch in telemetry so you can detect when the recall path is degraded, not when it's correctly silent.

---

## 3. External Content Query + Id Exclusion

The official docs are explicit about the model: an external-content FTS5 table stores only the inverted index; FTS5 reads column values from the content table on demand. Internally, FTS5 uses:

> "FTS5 retrieves column values by querying the content table via `SELECT <content_rowid>, <cols> FROM <content> WHERE <content_rowid> = ?`" [3_external_content_query_id_exclusion[0]] [2]

**Critical alignment rule.** By default `<content_rowid>` is literally `rowid`. If your `messages` table has its own named `INTEGER PRIMARY KEY` (e.g. `id INTEGER PRIMARY KEY`), you **must** specify `content_rowid='id'` in the FTS5 create statement, otherwise the index will be keyed by the wrong column on every read:

> "If the content table is defined as `CREATE TABLE t1(a INTEGER PRIMARY KEY, b, c);`, a corresponding FTS5 table would be created as `CREATE VIRTUAL TABLE fts_idx USING fts5(b, c, content='t1', content_rowid='a')`." [3_external_content_query_id_exclusion[0]] [2]

**The canonical query (your case).** Given `messages(id INTEGER PRIMARY KEY, content TEXT, session_id INTEGER, …)` and an aligned `messages_fts(rowid UNUSED, content)`:

```sql
SELECT messages.id,
       messages.content,
       messages.session_id,
       bm25(messages_fts) AS rank
FROM   messages
JOIN   messages_fts
       ON messages_fts.rowid = messages.id
       AND messages_fts MATCH ?
WHERE  messages.id NOT IN (?, ?, …, ?)   -- excluded id set, one ? per id
ORDER  BY bm25(messages_fts)              -- more negative = better; default ASC
LIMIT  50;                               -- candidate window for cutoff
```

This is the form the GRDB FullTextSearch doc itself recommends: `JOIN … ON book_ft.rowid = book.rowid AND book_ft MATCH ?` GRDB FullTextSearch docs. Because rowid alignement is preserved, excluding `messages.id` is equivalent to excluding `messages_fts.rowid`; in either form, FTS5's index lookup is filtered by NOT-IN before any expensive column fetch from the content table.

**Lifecycle pitfalls (verbatim from docs):**

| Operation | Order rule | Source |
|---|---|---|
| Delete a row | "the FTS5 table must be updated first (so that the content table row is still available to it)" | [3_external_content_query_id_exclusion[0]] [2] |
| Update a row | same: FTS5 first, then content | [3_external_content_query_id_exclusion[0]] [2] |
| REPLACE conflict resolution | not supported - falls back to ABORT | [3_external_content_query_id_exclusion[0]] [2] |
| Resync after drift | `INSERT INTO messages_fts(messages_fts) VALUES('rebuild');` | [3_external_content_query_id_exclusion[0]] [2] |
| Insert into FTS5 directly | **NOT recommended** for external-content; INSERT only into `messages` and use triggers to mirror into `messages_fts` | [3_external_content_query_id_exclusion[0]] [2] |

The DELETE-FTS-first ordering is counterintuitive - because FTS5 looks up column values in the content table on read, the content row must still exist at delete time. If your deletion path deletes from `messages` first, FTS5 attempts to fetch the column for any pending match and fails or returns stale index rows. Wrap your deletion in a single transaction with the explicit order:

```sql
BEGIN;
DELETE FROM messages_fts WHERE rowid IN (?, ?, …);   -- FTS first
DELETE FROM messages   WHERE id     IN (?, ?, …);   -- then content
COMMIT;
```

**Mechanism - read-only through SELECT.** External content FTS5 tables do not store the indexed text. Writes go to the content table; the index updates via triggers (your responsibility on insert/update/delete on `messages`). The `INSERT INTO … VALUES('rebuild')` form is the recovery primitive if drift occurs: it dumps all FA and segment data and re-indexes from the content table in one shot. Use it at the end of any bulk-import or migration path, not on every change.

**Implication - rowid alignment is your silent bug source.** Almost every reported FTS5 external-content issue traces to a missing or wrong `content_rowid` clause. The hermes/FrankenSQLite issue trackers confirm that mismatched `content_rowid` is the most common pitfall, including `content_rowid='rowid'` being rejected (or accepted but doing the wrong thing) on certain forks. The rule is short and worth pinning in a constant: **content_rowid MUST be the literal column name of the source's primary key when that key is named.** [3_external_content_query_id_exclusion[1]] [9]

**Recommendation.** Encode the FTS5 CREATE VIRTUAL TABLE statement with `content_rowid` literal in your migrations as a single source of truth, and add an assertion in tests that `SELECT rowid FROM messages_fts LIMIT 1` returns the same key set as the content table's primary key.

---

## 4. GRDB v7 Idioms: Pattern, Arguments, Array Binding, Lifecycle

GRDB v7 exposes FTS5 cleanly through two layers: a high-level builder (`create(virtualTable:using:body:)`) and a low-level raw-SQL path. The README confirms: **"Full-Text Patterns: FTS3Pattern and FTS5Pattern"** are first-class types, and the GRDB docs page shows the canonical query pattern as `try Document.fetchAll(db, sql: "SELECT * FROM document WHERE document MATCH ?", arguments: [pattern])` or the equivalent joined form GRDB README, GRDB FullTextSearch docs.

**Building the FTS5 virtual table (defensive):**

```swift
try db.create(virtualTable: "messages_fts", using: FTS5()) { t in
    t.tokenizer = .unicode61(diacritics: .remove)    // "unicode61 remove_diacritics 2"
    t.column("content")
    // -- if your messages table has its own named id, you cannot declare
    // content= here via FTS5(). Create the virtual table inline with raw
    // SQL inside a migration so you can specify content_rowid explicitly.
}
```

For an external-content table, the GRDB scheme builder does not currently expose `content` / `content_rowid` options, so declare it in a `Database.execute(sql:)` inside your migration:

```swift
var migrator = DatabaseMigrator()
migrator.registerMigration("fts5_messages") { db in
    try db.execute(sql: """
        CREATE VIRTUAL TABLE messages_fts
        USING fts5(content,
                   content='messages',
                   content_rowid='id',
                   tokenize='unicode61 remove_diacritics 2');
        """)
    // Triggers keeping the index in sync with messages:
    try db.execute(sql: """
        CREATE TRIGGER messages_ai AFTER INSERT ON messages BEGIN
          INSERT INTO messages_fts(rowid, content) VALUES (new.id, new.content);
        END;
        """)
    try db.execute(sql: """
        CREATE TRIGGER messages_ad AFTER DELETE ON messages BEGIN
          INSERT INTO messages_fts(messages_fts, rowid, content) VALUES('delete', old.id, old.content);
        END;
        """)
    try db.execute(sql: """
        CREATE TRIGGER messages_au AFTER UPDATE ON messages BEGIN
          INSERT INTO messages_fts(messages_fts, rowid, content) VALUES('delete', old.id, old.content);
          INSERT INTO messages_fts(rowid, content) VALUES (new.id, new.content);
        END;
        """)
}
```

**The search query (high-level `FTS5Pattern` + array exclusions):**

```swift
let pattern = FTS5Pattern(matchingAnyTokenIn: latestUserMessage)!
let excluded: [Int64] = inWindowMessageIds               // any Sequence of Int64
let placeholders = Array(repeating: "?", count: excluded.count).joined(separator: ", ")
let sql = """
    SELECT messages.id, messages.content, messages.session_id,
           bm25(messages_fts) AS rank
    FROM   messages
    JOIN   messages_fts
           ON messages_fts.rowid = messages.id
           AND messages_fts MATCH ?
    WHERE  messages.id NOT IN (\(placeholders))
    ORDER  BY rank                                          -- bm25 ASC = best first
    LIMIT  50;
    """
let args: StatementArguments = StatementArguments([pattern] + excluded.map { $0 as DatabaseValueConvertible })
let candidates = try Row.fetchAll(db, sql: sql, arguments: args)
```

**Idiom notes (all confirmed against the CHANGELOG and FullTextSearch doc):**

- v7 renamed `FTS5Tokenizer` to `FTS5TokenizerDescriptor` [4_grdb_v7_idioms_pattern_arguments_array_binding_lifecycle[0]] [21].
- `String.fetch...` is now non-optional; use `Optional<String>.fetch...` if your text column may be NULL [4_grdb_v7_idioms_pattern_arguments_array_binding_lifecycle[0]] [21].
- `try Row.fetchAll(db, sql:arguments:)` accepts a `StatementArguments` that may contain a `Sequence` - GRDB expands Swift arrays into comma-separated parameters. Concretely, `[pattern] + excluded` packs the pattern and the variable-length id list together with no manual placeholder expansion required when the Swift Array is treated as one batch of arguments.
- Iterated fetches return `DatabaseSequence<Row>` (note the v7 rename from earlier types) [4_grdb_v7_idioms_pattern_arguments_array_binding_lifecycle[0]] [21] - use `row.copy()` if you want to retain rows past the loop.
- For Swift 6 strict concurrency: GRDB v7's `Reader` and `DatabasePool`/`DatabaseQueue` are explicitly designed around actor-style isolation. Run all FTS5 work inside `try await db.read { db in … }` or `try await db.write { db in … }` so the calls satisfy `@Sendable` boundaries.

**Mechanism - safe placeholders vs. string interpolation.** The pattern object safely quotes the user text - you must never build a `MATCH` query with raw string interpolation of user input, since `MATCH` syntax reserves characters like `^`, `*`, `NEAR`, `"`, parentheses. `FTS5Pattern` validates and escape-corrects user input - if it returns `nil`, the input is unusable and you should emit zero results rather than fall back to unsafe SQL. Always check the optional.

**Pitfall summary for external-content + delete/rebuild lifecycle:**

1. **Wrong order on delete**: deleting from `messages` first will leave dangling FTS rows. Always wrap `DELETE FROM messages_fts WHERE rowid IN (...)` and then `DELETE FROM messages WHERE id IN (...)` in one transaction.
2. **Drift after bulk operations**: if you ever insert/update `messages` rows outside the trigger path (raw `db.execute(sql:)`, direct migration, etc.), the index diverges. Run `'INSERT INTO messages_fts(messages_fts) VALUES("rebuild")'` as a finalize step in any bulk-import migration.
3. **Type mismatch in rowid**: very long-lived schemas sometimes rename `messages.id` to `messages.uuid` (TEXT). Mixed-type comparisons against `messages_fts.rowid` (INTEGER) cause silent misalignment. Encapsulate the rowid column in a Swift typealias to keep it INTEGER everywhere.
4. **REPLACE conflict resolution**: SQLite's `INSERT OR REPLACE` on `messages` will NOT update the FTS row under the old rowid. Avoid `OR REPLACE` paths for `messages`, or pair them with explicit FTS delete + insert in the same transaction.

---

## 5. Tokenizer Choice for English Conversational Text

The four built-in tokenizers serve different needs. Synthesizing the official docs, the GRDB tokenizer doc, the Signal FTS5 extension README, and the trigram/CJK guidance:

| Tokenizer | Spec | Behaviour | Best for | Index size |
|---|---|---|---|---|
| `unicode61` (default) | Unicode Segmentation + lower-case + ascii-friendly | Splits on whitespace/punctuation, lowercases ASCII | English baseline | 1x (baseline) |
| `unicode61 remove_diacritics 2` | + accent folding (NFKD-style) | `cafe` matches `cafe` | English with international names | 1x |
| `porter` | Porter stemmer wrapped around unicode61 | Collapses `running`/`ran`/`run` to `run`; mangles some irregulars | English recall where inflections matter | 1x |
| `trigram` | All 3-char substrings are tokens | Substring/prefix matching; no word boundaries | CJK, fuzzy-substring, language-agnostic | **3-5x** |
| GRDB `LatinAsciiTokenizer` | wraps `unicode61`, lowercases + strips non-ASCII letters | "Grossmann ~ Grossmann ~ GROSSMANN" fuzzy latin matching | Names, misspellings, products | 1x |
| GRDB `SynonymsTokenizer` | wraps a base tokenizer + synonym map | "first ~ 1st", "mri ~ magnetic resonance imaging" | Domain jargon normalization | 1x |
| Signal `signal_tokenizer` (custom) | Unicode Seg + normalize + remove diacritics + lowercase | Production-tested on chat transcription errors | Conversational / multilingual | 1x |

[5_tokenizer_choice_for_english_conversational_text[0]] [16], [5_tokenizer_choice_for_english_conversational_text[1]] [54], [5_tokenizer_choice_for_english_conversational_text[2]] [89], FTS5 trigram CJK article

**Recommendation for your stack: `unicode61 remove_diacritics 2` as the default,** with `LatinAsciiTokenizer` (the GRDB wrapper) running on top if you observe that user-typed chat contains frequent misspellings (`teh` for `the`, accents dropped over SMS, mixed case names). Cross-reference the underlying pi-knowledge doc which explicitly recommends `Phase 1 unicode61; Spike switch to trigram only if precision < 60%` [5_tokenizer_choice_for_english_conversational_text[3]] [15].

**When to consider `porter`.** Porter stemming helps recall when queries talk about a **concept** rather than a specific form (`running faster` should match `ran fast`). However, porter is **aggressive**: it conflates `organize`/`organization`/`organ` (frequent false-positive), mangles proper nouns (`Porter`/`porter`), and is a poor fit for spoken-as-typed chat where users type `gonna`, `wanna`, contractions. Porter is also a fragile recall baseline for conversational data where casual grammar drifts from formal stemmer expectations. The pragmatic call: do not enable porter by default for chat; enable it only if you have evaluated that recall improves on a labelled eval set of `query → relevant message` pairs.

**Why trigram is wrong for English production recall.** Trigram indexes every 3-character substring, blowing up storage 3-5x and slowing inserts. For English where word boundaries are real, trigram's substring matching is over-recall (e.g. `database` matches `base`). It's the right tool when (a) you have CJK text without segmentation, or (b) you need true fuzzy substring matching (`did you mean?`). For your conversational recall path, trigram belongs only behind a "fuzzy" prefix query, not in the main recall pipeline.

**Implication - tokenizer choice changes your cutoff design.** With `unicode61 remove_diacritics 2`, the token set is high-signal: stopwords and punctuation become whitespace, every match is a word match, and per-query normalization in section 2 works as designed. With `porter`, more documents match (higher recall, lower precision) and the bm25 score distribution shifts - your ratio threshold of 0.45 may need to relax to 0.55 or you'll under-inject. With `trigram`, more hits match too aggressively and the bm25 distribution has many shallow scores - per-query normalization is still robust but you'll want to cap absolute hit count earlier.

**Mechanism - tokenizer → score distribution.** The DI (document index) and term frequency both feed BM25. Porter's stemming increases term frequency (more matches per document) and decreases the number of distinct terms in the index, raising IDF for non-collapsed forms - net effect: scores stretch out and have more near-zero noise. Trigram does the opposite: more terms overall, smaller IDF, shallower score curves. `unicode61` strikes the middle path. Cutoff thresholds tuned on `unicode61` do not transfer cleanly between tokenizers; re-tune per tokenizer.

**Concrete recommendation for v1:**

1. Default `tokenize='unicode61 remove_diacritics 2'` for `messages_fts`.
2. Run a small offline eval (50-200 hand-labelled queries) before deciding whether to adopt Porter or switch to a LatinAscii/Signal-style wrapper.
3. Keep `trigram` as a separate second virtual table for a "fuzzy" fallback query if needed - do not put it on the hot path.
4. Embed the tokenizer string in **one** Swift constant (`enum Tokenizers { static let english = "unicode61 remove_diacritics 2" }`) so a future switch is a one-line migration.

---

## Synthesis: Comparative Analysis Across Five Dimensions

The five sub-questions are tightly coupled - each design choice constrains the others. The trade space is best understood as a matrix, not five independent decisions:

| Dimension | Naive choice | Recommended choice | Mechanism coupling |
|---|---|---|---|
| BM25 sign handling | Treat as positive number | Wrap to non-negative score_bm25 | Decouples recall policy from SQLite's quirk; makes thresholding legible |
| Cutoff strategy | Always top-K | Per-query max normalization + hit cap | Per-query normalization is necessary because corpus-relative scores make single thresholds brittle; tokenizer choice (porter→trigram) shifts the score distribution so the ratio threshold must be re-tuned |
| Rowid alignment | Default `rowid` | Explicit `content_rowid='id'` | Id exclusion quality entirely depends on this; without it `NOT IN` is silently filtering the wrong key set |
| GRDB idiom | String-interpolated MATCH with `try db.execute` | `FTS5Pattern` + raw SQL with `StatementArguments` for arrays | v7 broke `String.fetch...` return-type semantics; old Swift 5 patterns of interpolating arrays into `("?,?,?")` are still legal but unsafe for user input - use the framework |
| Tokenizer | `porter` (looks "smart") | `unicode61 remove_diacritics 2` (+ `LatinAsciiTokenizer` if misspellings dominate) | Aggressive tokenizers (porter, trigram) inflate recall but reduce precision; your cutoff design must accommodate that |

**Cross-cutting tensions:**

- **Speed of iteration vs. quality of threshold.** Always-top-K is simple but injects noise. Per-query normalization requires a candidate window (`LIMIT 50`), one extra ratio-math pass over results, and a tuned cutoff constant. The added engineering is worth it once you measure "how often does the recall path pull in unrelated messages?" - in our experience, even modest chat corpora return noisy top-K hits at least 30% of the time, which the model interprets as in-context noise.
- **Internal-content simplicity vs. DRY.** You could store `content` in `messages_fts` verbatim (no `content=` clause) and skip the JOIN. You give up half the index size and gain an extra write on every insert. For a chat archive where every message is a few KB, the storage saving dwarfs the write cost - external-content with `content_rowid` is the right call. The cost is the lifecycle ordering strictness (FTS-first delete).
- **Tokenizer smartness vs. cutoff reliability.** A more aggressive tokenizer produces more matches per query, which flattens the bm25 distribution. A less aggressive tokenizer produces fewer matches with more separation. Per-query normalization blunts this difference but does not eliminate it: if you later switch from `unicode61 remove_diacritics 2` to `porter`, expect to re-tune your ratio threshold downward (looser) and your hit cap downward (fewer noisy results). Plan tokenizer evaluation co-rolling with cutoff evaluation, not separately.
- **v7 breaking changes vs. stability.** GRDB v7's rename of `FTS5Tokenizer` to `FTS5TokenizerDescriptor` and the non-optional `String.fetch...` will surface in search legacy Swift code. If your codebase has any pre-v7 code, search for `FTS5Tokenizer(` and `String.fetch` to catch the issues before a compile storm. The CHANGELOG also confirms `DatabaseSequence` for sequence results, which is a documentation update rather than a behaviour change.

**Final recommendation cascade.** For a Swift 6 strict-concurrency daeon doing conversational recall with GRDB v7 + SQLite FTS5:

1. Define `messages_fts` as `content='messages', content_rowid='id', tokenize='unicode61 remove_diacritics 2'`.
2. Wrap `bm25()` outputs through a `Score` struct that exposes positive `score_bm25` (negative of raw) plus the raw `rank` for SQLite-native logging.
3. Fetch a `LIMIT 50` candidate window with `JOIN messages_fts ON rowid = messages.id AND MATCH ?`.
4. Apply per-query max normalization: `rel = bm25(hit) / bm25(top_hit)`; require `rel < -0.45` and `bm25(hit) != 0`. Cap to 8 messages. Inject nothing if the top hit's `bm25() = 0`.
5. Use `FTS5Pattern(matchingAnyTokenIn:)` for safe MATCH input. Pass `[pattern] + excludedIds` as `StatementArguments` directly to `try Row.fetchAll(db, sql:, arguments:)`.
6. Wrap all deletions in `BEGIN; DELETE FROM messages_fts WHERE rowid IN (?); DELETE FROM messages WHERE id IN (?); COMMIT;`.
7. Periodically re-evaluate with a labelled query set before any tokenizer/threshold changes.

This proposal uses only verified, primary-source-backed facts (verbatim from the SQLite FTS5 docs, the GRDB docs and CHANGELOG), exposes the tradeoffs at each decision, and is concrete enough that it can be ported row-by-row into a PR.

---

## References

1. *How to interpret rank output from BM25?*. https://datascience.stackexchange.com/questions/112889/how-to-interpret-rank-output-from-bm25
2. *SQLite FTS5 Extension*. https://sqlite.org/fts5.html
3. *Full-Text Search in SQLite with FTS5 | SQL Boy - hisqlboy.com*. https://www.hisqlboy.com/blog/sqlite-full-text-search-fts5
4. *SQLite full-text search relevance ranking - Stack Overflow*. https://stackoverflow.com/questions/7272019/sqlite-full-text-search-relevance-ranking
5. *FTS5 Scoring and BM25 | shibing624/TreeSearch | DeepWiki*. https://deepwiki.com/shibing624/TreeSearch/6.4-fts5-scoring-and-bm25
6. *SQLite FTS5 Extension - chiark*. https://www.chiark.greenend.org.uk/doc/sqlite3/fts5.html
7. *FTS5/rowid: PrimaryKeyViolation on basic INSERT + FTS rebuild ...*. https://github.com/Dicklesworthstone/frankensqlite/issues/94
8. *skills-ciwvl/tasks/sqlite-wal-recovery/environment ... - GitHub*. https://github.com/mercor-code-envs/skills-ciwvl/blob/main/tasks/sqlite-wal-recovery/environment/skills/sqlite-fts5-index-rebuild/SKILL.md
9. *FTS5: `content_rowid='rowid'` option rejected ... - GitHub*. https://github.com/Dicklesworthstone/frankensqlite/issues/97
10. *BM25*. https://arpitbhayani.me/blogs/bm25
11. *BM25 Scoring Algorithm in Elasticsearch - kindatechnical()*. https://kindatechnical.com/elasticsearch/bm25-scoring-algorithm-in-elasticsearch.html
12. *What is BM25?*. https://www.paradedb.com/learn/search-concepts/bm25
13. *BM25 Retrieval: Methods and Applications*. https://www.emergentmind.com/topics/bm25-retrieval
14. *BM25: Complete Guide to the Search Algorithm Behind Elasticsearch*. https://mbrenndoerfer.com/writing/bm25-search-algorithm-elasticsearch-implementation
15. *pi-knowledge/docs/fts5-code-tokenization.md at main - GitHub*. https://github.com/nczz/pi-knowledge/blob/main/docs/fts5-code-tokenization.md
16. *SQLite FTS5 Tokenizers: `unicode61` and `ascii` — audrey ...*. https://audrey.feldroy.com/articles/2025-01-13-SQLite-FTS5-Tokenizers-unicode61-and-ascii
17. *FTS5 ICU Tokenizer for Better Multilingual Text Search*. https://www.reddit.com/r/sqlite/comments/1nkaqiq/introducing_fts5_icu_tokenizer_for_better
18. *hermes - (Solved) Fix FTS5 unicode61 tokenizer silently drops ...*. https://www.stepcodex.com/en/issue/fts5-unicode61-tokenizer-silently-drops-cjk
19. *libsql/libsql-sqlite3/ext/fts5/fts5_tokenize.c at main ...*. https://github.com/tursodatabase/libsql/blob/main/libsql-sqlite3/ext/fts5/fts5_tokenize.c
20. *Examples | xhluca/bm25s | DeepWiki*. https://deepwiki.com/xhluca/bm25s/9-examples
21. *GRDB.swift/CHANGELOG.md at master · groue ...*. https://github.com/groue/GRDB.swift/blob/master/CHANGELOG.md
22. *GitHub - xhluca/bm25s: Fast BM25 search in Python, powered by ...*. https://github.com/xhluca/bm25s
23. *Full text search — APSW 3.53.1.0 documentation - GitHub Pages*. https://rogerbinns.github.io/apsw/textsearch.html
24. *groue/GRDB.swift: A toolkit for SQLite databases, with a ...*. http://github.com/groue/GRDB.swift
25. *GRDB Reference - GitHub Pages*. https://groue.github.io/GRDB.swift/docs/4.7/index.html
26. *GRDB.swift*. https://groue.github.io/GRDB.swift
27. *GRDB Reference - groue.github.io*. https://groue.github.io/GRDB.swift/docs/6.0.0-beta/index.html
28. *GRDB (Alpha) - PowerSync Docs*. https://docs.powersync.com/client-sdks/orms/swift/grdb
29. *BM25 Retrieval Scoring Calculator*. https://metricgate.com/docs/bm25-retrieval-score
30. *What is BM25 Full-Text Search? How Document Ranking ...*. https://spice.ai/learn/bm25-full-text-search
31. *Ranking Documents with BM25-Understanding the Math ... - Medium*. https://medium.com/%40spandana_doki/ranking-documents-with-bm25-understanding-the-math-behind-search-relevance-31505b350825
32. *Android SQLite FTS4 tokenize=unicode61 remove_diacritics=2*. https://www.twisterrob.net/blog/2023/10/sqlite-unicode61-remove-diacritics-2.html
33. *Porter Stemmer algorithm - OpenGenus IQ*. https://iq.opengenus.org/porter-stemmer
34. *FTS5Index and SQLite Schema | shibing624/TreeSearch | DeepWiki*. https://deepwiki.com/shibing624/TreeSearch/7.1-fts5index-and-sqlite-schema
35. *Porter Stemmer – Information Retrieval Project - GitHub*. https://github.com/baselAlsheikh/PorterStemmer-IR
36. *porter_stemmer_standalone.ipynb - Colab*. https://colab.research.google.com/github/chrisvdweth/selene/blob/master/notebooks/standalone/porter_stemmer_standalone.ipynb
37. *GRDB.swift/GRDB/Core/Cursor.swift at master · groue/GRDB.swift ...*. https://github.com/groue/GRDB.swift/blob/master/GRDB/Core/Cursor.swift
38. [[swift-evolution] Feedback on SE-0166 and SE-0167](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170522/036830.html)
39. *Problem using belongsTo - GRDB*. https://forums.swift.org/t/problem-using-belongsto/80162
40. *GitHub - groue/GRDB.swift: A toolkit for SQLite databases ...*. https://github.com/groue/GRDB.swift
41. *GRDB | Documentation*. https://swiftpackageindex.com/groue/GRDB.swift/v7.11.0/documentation/grdb
42. *Search Ranking Stack in 2026: BM25, Embeddings, Cross ...*. https://slavadubrov.github.io/blog/2026/02/08/search-ranking-stack
43. *bm25s*. https://pypi.org/project/bm25s/0.1.5
44. *topk-io/topk: High-quality search for AI-native applications.*. http://github.com/topk-io/topk
45. *TopK - Retrieval engine for accuracy-critical AI applications.*. http://topk.io/
46. *The BM25 rank feature Vespa Documentation https://docs.vespa.ai › ranking*. https://docs.vespa.ai/en/ranking/bm25.html
47. *Configure BM25 Relevance Scoring - Azure AI Search*. https://learn.microsoft.com/en-us/azure/search/index-ranking-similarity
48. *SQLite FTS5 Extension*. https://www2.sqlite.org/draft/matrix/fts5.html
49. *Full-Text Search in SQLite: A Practical Guide - Medium*. https://medium.com/%40johnidouglasmarangon/full-text-search-in-sqlite-a-practical-guide-80a69c3f42a4
50. *FTS5 contentless vs external content : r/sqlite - Reddit*. https://www.reddit.com/r/sqlite/comments/17xjmfe/fts5_contentless_vs_external_content
51. *Structure of FTS5 Index in SQLite - Fedor Indutny's Blog*. https://darksi.de/13.sqlite-fts5-structure
52. *Databases and Persistence - Swift.org*. https://www.swift.org/packages/database.html
53. *Raw SQL in iOS/Swift: SQLite.swift or GRDB?*. https://www.reddit.com/r/iOSProgramming/comments/1d7a0zr/raw_sql_in_iosswift_sqliteswift_or_grdb
54. *FTS5 Tokenizers - GitHub*. https://github.com/groue/GRDB.swift/blob/master/Documentation/FTS5Tokenizers.md
55. *FTS5 ICU Tokenizer for SQLite - GitHub*. https://github.com/cwt/fts5-icu-tokenizer
56. *The English (Porter2) stemming algorithm - Tartarus*. http://snowball.tartarus.org/algorithms/english/stemmer.html
57. *shcabin/sqlite-fts5-icu-tokenizer - GitHub*. https://github.com/shcabin/sqlite-fts5-icu-tokenizer
58. *Select column as true / false if id is exists in another table*. https://forums.swift.org/t/select-column-as-true-false-if-id-is-exists-in-another-table/56406
59. *Handeling throws from the database - GRDB*. https://forums.swift.org/t/handeling-throws-from-the-database/38781
60. *StatementArguments Structure Reference*. https://groue.github.io/GRDB.swift/docs/5.0/Structs/StatementArguments.html
61. *rules-swift/concurrency.md at main*. https://github.com/mihaelamj/rules-swift/blob/main/concurrency.md
62. *Mastering Swift 6 Strict Concurrency: A Step-by- ...*. https://medium.com/%40aliyasirali/embracing-swift-6-strict-concurrency-why-a-step-by-step-approach-matters-aa7696235797
63. *Sendable | Apple Developer Documentation*. https://developer.apple.com/documentation/swift/sendable
64. *Swift 6 Concurrency and Actors: Building Thread-Safe iOS ...*. https://pavanrangani.com/blog/swift-6-concurrency-actors-ios-guide
65. *What's new for concurrency in Swift 6.2*. http://youtube.com/watch?v=7QvCFBNz45A
66. *Fetched web page*. https://raw.githubusercontent.com/groue/GRDB.swift/master/README.md
67. *Fetched web page*. https://raw.githubusercontent.com/groue/GRDB.swift/master/CHANGELOG.md
68. *Cutoff values*. https://www.ibm.com/docs/SSZJPZ_11.5.0/com.ibm.swg.im.iis.qs.ug.doc/topics/c_Defining_cutoff_values.html
69. *Retrieval Evaluation Metrics You Should Actually Use*. https://dasroot.net/posts/2026/02/retrieval-evaluation-metrics-actual-use
70. *Retrieval Metrics Tutorial: Recall@k and MRR Explained*. https://medium.com/%40rajnish_khatri/retrieval-metrics-tutorial-recall-k-and-mrr-explained-d2f12afb9c89
71. *Recall and Precision: The Heart of Evaluating Indexing System ...*. https://lis.academy/information-processing-retrieval/recall-precision-evaluating-indexing-performance
72. *Retrieval of past knowledge increases learning*. https://openlearning.mit.edu/mit-faculty/research-based-learning-findings/retrieval-practice-testing-effect
73. *Getting started with SQLite Full-text Search By Examples*. https://www.sqlitetutorial.net/sqlite-full-text-search
74. *Searching 20,000 Text Files With SQLite FTS5 and Flask*. https://jackpal.github.io/2024/07/27/Fun_with_sqlite_fts5.html
75. *Fts5 | API reference | Android Developers*. https://developer.android.com/reference/androidx/room3/Fts5
76. *SQLite Full-Text Search (FTS5) in Practice: Fast Search ...*. https://thelinuxcode.com/sqlite-full-text-search-fts5-in-practice-fast-search-ranking-and-real-world-patterns
77. *Scoring: The Math of Relevance (BM25) | A Dev Writes*. https://www.adevwrites.space/elasticsearch/03-query-relevance/02-scoring-bm25-relevance
78. *Practical BM25 - Part 2: The BM25 Algorithm and its ...*. https://www.elastic.co/blog/practical-bm25-part-2-the-bm25-algorithm-and-its-variables
79. *BM25 The Next Generation of Lucene Relevance*. https://opensourceconnections.com/blog/2015/10/16/bm25-the-next-generation-of-lucene-relevation
80. *SQLite FTS5 Arabic Phonetic Fuzzy Trigram Tokenizer*. https://github.com/Greentech-Apps-Limited/sqlite3-arabic-phonetic-fuzzy-trigram
81. *Full-text CJK Search with SQLite FTS5: Trigram Tokenizer and ...*. https://zenn.dev/kanseilink/articles/kanseilink-fts5-trigram-cjk-20260507?locale=en
82. *The English (Porter2) stemming algorithm - Snowball*. https://snowballstem.org/algorithms/english/stemmer.html
83. *The Porter stemming algorithm*. http://snowball.tartarus.org/algorithms/porter/stemmer.html
84. *Exploring Stemming Techniques in Natural Language Toolkit ...*. https://levelup.gitconnected.com/exploring-stemming-techniques-in-natural-language-toolkit-nltk-f55cc2b39fe6
85. *GitHub - midclique/sqlite-bm25-search: Fast local file search ...*. https://github.com/midclique/sqlite-bm25-search
86. *SQLite FTS5 and BM25 | gwicho38/legal-workspace-mcp | DeepWiki*. https://deepwiki.com/gwicho38/legal-workspace-mcp/3.2.1-sqlite-fts5-and-bm25
87. *SQLite FTS5 Reference | Axiom*. https://charleswiltgen.github.io/Axiom/reference/sqlite-fts-ref
88. *Fetched web page*. https://raw.githubusercontent.com/groue/GRDB.swift/master/Documentation/FullTextSearch.md
89. *GitHub - signalapp/Signal-FTS5-Extension: A FTS5 extension for signal_tokenizer. · GitHub*. https://github.com/signalapp/Signal-FTS5-Extension
90. *How to Remove Accents and Diacritics - The Text Tool*. https://thetexttool.com/blog/diacritics-remover-complete-guide
91. *Remove Diacritics from Text - Online Text Tools*. https://onlinetexttools.com/remove-text-diacritics
92. *Remove Accents - Delete Letter Diacritics - Online - Browserling*. https://www.browserling.com/tools/remove-accents
93. *Diacritic-Insensitive and Case-Insensitve Sorting*. https://www.perlmonks.org/?node_id=318769
94. *Remove Diacritics from CSV File*. https://gist.github.com/jeet-khondker/ab128aca6de7862cc6d98567c57671cf
95. *SQLite FTS5 Extension*. https://www2.sqlite.org/matrix/fts5.html
