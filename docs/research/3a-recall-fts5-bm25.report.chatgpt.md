# Deep research on SQLite FTS5 conversational recall with GRDB v7

## Bottom line

For your stack and use case, the strongest design is to treat SQLite FTS5 as a **candidate generator**, not as a calibrated oracle. In practice that means: search the external-content FTS5 table with a validated `FTS5Pattern`, rank with `ORDER BY rank` ascending, exclude the live-window message IDs at the FTS side via `rowid NOT IN (...)`, join the resulting `rowid`s back to `messages.id`, and then apply a **query-local cutoff** based on the score shape of that result set rather than a fixed global BM25 number. That recommendation follows from SQLite’s own BM25 design, which makes better matches numerically smaller, from the fact that FTS5’s score depends on corpus-wide statistics such as average document length and document frequency, and from current search-engine guidance that BM25 scores are not cleanly bounded or directly comparable across queries. citeturn12view0turn2view0turn15view0turn15view1

For tokenizer choice, the safest default for general English conversational recall is **`unicode61` with diacritics folding**. If you want more recall on English inflections, test **`porter unicode61`** on your own archive and accept that it will broaden matches. I would **not** use `trigram` for this workload unless substring retrieval becomes a first-class requirement, because trigram changes the search unit from words to arbitrary character substrings and introduces many more weak matches, which makes cutoff design harder rather than easier. citeturn14view0turn19view0

## BM25 behavior in SQLite FTS5

SQLite FTS5’s built-in `bm25()` is deliberately inverted compared with the usual “higher is better” intuition. The official docs say that `bm25()` returns a real value where **better matches are numerically smaller**, and they explicitly explain that SQLite multiplies the conventional BM25 result by `-1` so that a plain ascending sort returns the best matches first. In other words, your belief is directionally correct: the safe invariant is **lower = better**, and in ordinary use you will typically observe negative or near-zero values rather than positive “relevance points.” citeturn1view0turn12view0

So the correct ordering for “best match first” is:

```sql
SELECT rowid, bm25(messages_fts) AS score
FROM messages_fts
WHERE messages_fts MATCH ?
ORDER BY score;
```

and **not** `ORDER BY score DESC`. SQLite also provides the hidden `rank` column, which in a full-text query defaults to the same value as `bm25()` with no trailing arguments. The docs note that `ORDER BY rank` is logically equivalent to `ORDER BY bm25(ft)` but can be faster, especially when you also use `LIMIT` or stop reading before exhausting the cursor. citeturn12view0

That makes this the preferred default shape:

```sql
SELECT rowid, rank
FROM messages_fts
WHERE messages_fts MATCH ?
ORDER BY rank
LIMIT ?;
```

If you ever add more indexed columns and want custom BM25 column weights, SQLite recommends remapping the `rank` column per query, for example with `rank MATCH 'bm25(10.0, 5.0)'`, and then still sorting by `rank`. With a single indexed `content` column, column weights are not relevant. citeturn12view0

On scale, the key point is that SQLite’s BM25 is **not an absolute, portable score**. Its formula depends on query phrase frequencies, document length `|D|`, average document length `avgdl`, the number of rows `N`, and the document frequency `n(q_i)` for each query phrase. Those are all corpus-relative statistics, so score magnitudes shift as your archive grows, as tokenization changes, and as the query itself changes. That is the core reason a fixed numeric cutoff is brittle. citeturn12view0turn2view0

## A robust minimum-relevance cutoff

A fixed absolute threshold is the most tempting option and the weakest one here. It is easy to implement, but because SQLite’s BM25 depends on corpus-level statistics and BM25 scores are not strictly bounded, a threshold that looks good on today’s archive can silently drift as the corpus grows, as session mix changes, or as you switch tokenizers. Even official Elasticsearch guidance for hybrid retrieval treats BM25 as a score source with no clearly defined bounds and normalizes it per query when it must be combined with other score types. citeturn12view0turn15view0turn15view1

Always taking top-K is robust only in the narrow sense that it always returns something. For conversational recall, that is usually the wrong failure mode: when nothing is truly related, top-K guarantees that you inject noise into the LLM context anyway. That can hurt more than returning nothing, especially in a recall setting where the downstream model will tend to over-trust retrieved context if you provide it. This is an engineering inference from the ranking properties above, but it follows directly from the fact that top-K ignores whether the head of the ranking is well separated from the tail. citeturn12view0turn15view1

Per-query normalization is useful in one specific situation: **comparing or combining heterogeneous scorers**, such as BM25 and kNN. Elastic’s own documentation uses min-max normalization precisely because BM25 is not strictly bounded and can vary wildly across queries. But that same property is why min-max normalization is a poor standalone “minimum relevance” gate for pure BM25 recall: if all candidates are bad, min-max still forces the best bad result to look like `1.0` relative to the rest. Normalization preserves **within-query ordering**, not absolute usefulness. citeturn15view0turn15view1

For pure FTS5/BM25 recall, the best option among the ones you listed is a **score-gap or elbow heuristic**, ideally tuned on a held-out set of past conversations. Retrieve a modest candidate window such as the top 8–12 hits, sort ascending by `rank`, and inspect the gaps:

- let `s0 <= s1 <= s2 ...` be the returned `rank` values
- compute `g_i = s_{i+1} - s_i`
- keep the head of the list only up to the first clearly large gap, or up to the largest gap within the first few results
- if there is no convincing head-and-tail separation, inject nothing

Because SQLite’s FTS5 makes “better = smaller,” a large positive jump from `s_i` to `s_{i+1}` means relevance likely fell off sharply after item `i`. This approach is more stable than an absolute threshold because it relies on **the shape of the current query’s own result distribution**, not on a corpus-global magic number. The principled way to implement it is to tune the candidate window size and drop-off rule on labeled historical turns where you know whether the injected recall helped or hurt. citeturn12view0turn15view1

My practical recommendation is therefore:

```text
Use top-M retrieval + query-local gap cutoff, not a fixed top-K and not a fixed BM25 floor.
```

If you later add a second-stage reranker or vectors, revisit normalization. Until then, for FTS5-only conversational recall, the gap/elbow approach is the least brittle option. citeturn15view0turn15view1

## The correct external-content query and rowid caveats

With an external-content FTS5 table, SQLite stores the index in the FTS table but reads the actual column values from the content table using the configured `content_rowid`. By default that is `rowid`, but if your content table is `messages(id INTEGER PRIMARY KEY, ...)` then the correct FTS declaration is `content='messages', content_rowid='id'`. In that setup, the FTS table’s hidden `rowid` is the value you join back to `messages.id`. citeturn2view0turn14view0

A correct ranked query with an exclusion set looks like this:

```sql
WITH hits AS (
    SELECT
        rowid AS message_id,
        rank  AS score
    FROM messages_fts
    WHERE messages_fts MATCH :pattern
      AND rowid NOT IN (:excluded_ids...)
    ORDER BY rank
    LIMIT :candidate_limit
)
SELECT
    m.*,
    h.score
FROM hits AS h
JOIN messages AS m
  ON m.id = h.message_id
ORDER BY h.score, m.id;
```

That query does three important things correctly. It searches the **FTS table**, not the content table; it sorts by `rank` ascending, which is “best first” in FTS5; and it joins back on `messages.id = messages_fts.rowid`, which is the correct alignment for an external-content table configured with `content_rowid='id'`. GRDB’s own documentation recommends this exact “joined raw SQL request” pattern when you need content-table columns and full-text search in the same query. citeturn12view0turn19view0

There are several caveats worth watching closely with external-content tables. First, **consistency is your responsibility**. SQLite warns that if the FTS index and the content table diverge, results become unintuitive. In particular, if a query does **not** use `MATCH` or equivalent table-valued syntax, it is effectively passed through to the content table. That means `SELECT * FROM messages_fts` is **not** a reliable sanity check for the state of the FTS index. A `MATCH` query, by contrast, uses the index and then asks the content table for rows by `content_rowid`. citeturn2view0

Second, if you ever created synchronization triggers **after** `messages` already contained rows, those existing rows were not retroactively indexed by the trigger creation itself. SQLite explicitly says that in such cases the content table and the FTS index remain inconsistent until you rebuild or backfill. The official recovery command is:

```sql
INSERT INTO messages_fts(messages_fts) VALUES('rebuild');
```

That discards the existing FTS index and rebuilds it from the current contents of the content table. citeturn3view0turn2view0

Third, when you maintain external-content rows manually rather than via triggers, SQLite notes an ordering constraint for updates and deletes: the FTS table needs access to the **old content-table row** in order to remove the right tokens. So for synchronized update/delete behavior, the FTS side must effectively be updated before the content row disappears. If you use GRDB’s automatic synchronization triggers, that bookkeeping is handled for you; if you implement your own delete/rebuild path, keep this rule in mind. citeturn3view0turn2view0turn19view0

One more operational note matters for BM25-heavy recall: SQLite says the built-in `bm25()` uses the `xColumnSize` API, backed by the FTS5 `columnsize` storage. If you configure `columnsize=0`, BM25 still works for non-contentless tables, but it becomes slower because token counts are recomputed on demand. For a recall pipeline that ranks on every query, keeping the default `columnsize=1` is the right choice. citeturn3view0

## Idiomatic GRDB v7 implementation

GRDB’s modern FTS5 flow matches your use case well. For user-provided text, use `FTS5Pattern` instead of interpolating raw MATCH syntax yourself. GRDB provides non-throwing initializers such as `matchingAnyTokenIn`, `matchingAllTokensIn`, `matchingAllPrefixesIn`, `matchingPhrase`, and `matchingPrefixPhrase`, and it documents that these initializers build valid patterns from untrusted input. If you intentionally want to support advanced FTS syntax, `Database.makeFTS5Pattern(rawPattern:forTable:)` validates that raw expression against the query grammar and the target table. citeturn19view0

For simple cases, GRDB’s query interface is straightforward:

```swift
let documents = try Document.matching(pattern)
    .order(Column.rank)
    .fetchAll(db)
```

That is the idiomatic GRDB way to express “search this FTS5 table and order by relevance.” But GRDB’s own documentation is explicit that when you have an **external-content** FTS table and need columns from the regular table at the same time, the right solution is a **joined raw SQL request**. In other words, for your real query shape, raw SQL plus GRDB SQL interpolation is not a fallback; it is the documented pattern. citeturn19view0

A good GRDB v7 implementation therefore looks like this:

```swift
import GRDB

struct RecallHit: FetchableRecord, Decodable {
    let messageID: Int64
    let content: String
    let score: Double
}

func fetchRecallHits(
    db: Database,
    latestUserMessage: String,
    excluding excludedIDs: [Int64],
    limit: Int = 8
) throws -> [RecallHit] {
    guard let pattern = FTS5Pattern(matchingAnyTokenIn: latestUserMessage) else {
        return []
    }

    let exclusionSQL: SQL = excludedIDs.isEmpty
        ? SQL("")
        : SQL("AND rowid NOT IN \(excludedIDs)")

    let sql: SQL = """
        WITH hits AS (
            SELECT
                rowid AS messageID,
                rank  AS score
            FROM messages_fts
            WHERE messages_fts MATCH \(pattern)
              \(literal: exclusionSQL)
            ORDER BY rank
            LIMIT \(limit)
        )
        SELECT
            m.id      AS messageID,
            m.content AS content,
            h.score   AS score
        FROM hits AS h
        JOIN messages AS m
          ON m.id = h.messageID
        ORDER BY h.score, m.id
        """

    return try RecallHit.fetchAll(db, sql)
}
```

The important GRDB idioms here are all documented. `FTS5Pattern` is bound as a query argument instead of being string-concatenated. SQL interpolation binds values safely by default. Arrays interpolate correctly into `IN (...)` clauses. `SQL` fragments let you conditionally include the exclusion clause when the array is non-empty. And `literal:` is reserved for trusted SQL fragments, not user data. citeturn19view0turn18view0turn18view1turn18view2

There are only a few pitfalls to avoid. Do **not** construct MATCH expressions by raw string concatenation when the source is user text; use `FTS5Pattern`. Do **not** write `NOT IN ()`; omit that clause when the exclusion list is empty. Do **not** use `literal:` for user content. And if you use GRDB’s trigger-based synchronization helpers, remember that dropping the FTS table does not automatically drop the synchronization triggers on the content table; GRDB provides `dropFTS5SynchronizationTriggers` for that cleanup. citeturn19view0turn18view1

## Tokenizer recommendation for English conversational text

For general English conversational text, **`unicode61` is the safe default**. SQLite documents it as the default FTS5 tokenizer; it is Unicode-aware, case-insensitive according to Unicode rules, and by default removes diacritics from Latin script characters. GRDB’s FTS5 documentation says the same thing plainly: `unicode61` matches case-insensitively across Unicode characters and folds Latin diacritics by default, but it does **not** do stemming. That gives you a conservative lexical search behavior that tends to preserve precision. citeturn14view0turn19view0

If your archive is mostly English and you want “database” to match “databases” or “correcting” to match “correction,” then **`porter unicode61`** is the next thing to test. SQLite defines `porter` as a wrapper tokenizer that stems the output of another tokenizer and notes that it is designed for English. GRDB documents the same behavior and shows that `.porter()` wraps `.unicode61()` by default. The tradeoff is predictable: stemming broadens the effective postings lists, which usually improves recall but can make marginal matches more common. In practical terms, that means a fixed absolute cutoff becomes even less attractive, and query-local cutoff methods become more important. citeturn14view0turn19view0

I would avoid **`trigram`** for this workload. SQLite is very clear that trigram is for general substring matching, not normal token matching. A trigram query term can match any character sequence inside a row, and queries shorter than three Unicode characters do not match anything at all. Trigram also supports indexed `LIKE` and `GLOB` patterns under certain configurations, which is useful for substring search, but that is not the retrieval behavior you want for “find the most relevant past messages for conversational recall.” In conversational memory, trigram usually widens the candidate pool with weak substring hits, which makes ranking and cutoff decisions noisier. citeturn14view0

So the recommendation is:

- start with **`unicode61`** if you want the most predictable lexical matches
- test **`porter unicode61`** if English morphological recall matters enough to justify broader candidate sets
- skip **`trigram`** unless substring recall is explicitly required

In your exact use case, I would start with `unicode61`, measure misses caused by inflectional variants, and only then test `porter`. That order keeps the retrieval distribution tighter and makes your no-result cutoff more stable early on. citeturn14view0turn19view0

One optional nuance is worth calling out because your archive is likely to contain some code-ish text. SQLite’s `unicode61` tokenizer lets you customize token boundaries with `tokenchars` and `separators`, and the docs show examples such as treating hyphens and underscores as token characters. If your messages often contain identifiers like `snake_case`, hyphenated package names, or Swift symbols, that kind of tokenizer tuning can materially improve recall quality. Also, GRDB warns that Unicode normalization mismatches can cause surprising misses, so normalizing indexed content and queries consistently is worth doing if your inputs come from mixed sources. citeturn14view0turn19view0