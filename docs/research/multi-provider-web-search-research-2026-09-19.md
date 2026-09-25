# Multi-provider web search: implementations, evidence, and a decision for swift-claw

Research date: **19 September 2026**. Related proposal: [issue #228](https://github.com/ivan-magda/swift-claw/issues/228).

This is research and an experimental recommendation, not an accepted architecture change.
The local OpenClaw and Hermes checkouts were inspected alongside public source code,
research papers, and published evaluations. No paid search experiments were run.
Implementation observations are pinned to commits; an implementation's existence is
not evidence that it improves answer quality.

## Decision

**The capability is real and worth a bounded experiment. The evidence does not justify
making four-provider fanout the default for every search.**

There are close precedents, including an external OpenClaw Search Fusion plugin,
Hermes Web Search Plus's research mode, an agent-oriented Rust search CLI, and AI
answering systems built on SearXNG. The built-in OpenClaw and Hermes search paths,
however, primarily select one provider and recover through fallback. Supporting many
providers in configuration is different from combining their successful responses.

For swift-claw, retain the single-provider baseline and evaluate **Exa plus one additional
result-oriented API** behind the existing `web_search` tool. Compare simple rank fusion
with a budget-matched single-provider strategy, not just one call versus two. Keep the
final evidence budget fixed. Adopt fusion where it measurably improves grounded task
success or availability at an acceptable total cost; preserve ordinary single-provider
search where the added call buys little.

The strongest general evidence concerns classical retrieval and complementary candidate
sets. Direct modern agent evidence is much weaker: one inspected public experiment
reports a positive result on 50 questions, but it is small, self-published, and lacks a
strongest-constituent and equal-budget comparison. No large, independently replicated
study establishing a universal multi-provider advantage was found in the sources reviewed.

## What counts as multi-provider search

| Pattern | What actually happens | What it can establish |
|---|---|---|
| Provider selection | One configured API receives a query | Portability and owner choice |
| Sequential fallback | Another API runs after failure or an inadequate response | Recovery; successful first responses are not enriched |
| Multi-query search | Several formulations go to one API | Query diversity, not provider diversity |
| Agent-orchestrated tools | The model chooses different search tools over several steps | Adaptive research; not necessarily deterministic fusion |
| Metasearch / result fusion | Several providers search, then their results are merged and selected | Additional candidate coverage and potentially better ranking |
| Answer ensemble | Several systems generate answers and another model reconciles them | A different intervention with additional synthesis and attribution risks |

The proposed feature is the fifth pattern. It can run inside swift-claw or behind one
metasearch endpoint. The location of the aggregation changes operational responsibility
and observability, but not the underlying idea.

## Verified implementations

| Project and inspected revision | Actual behavior | Relevance to this proposal |
|---|---|---|
| OpenClaw `88a48ac42f4e` | One selected provider; sequential fallback for implicit selection; SearXNG adapter available | Good provider boundary and recovery reference; native direct-API fusion absent in audited path |
| Hermes Agent `3eb9712180ec` | One selected search provider with recovery paths | Same distinction: provider support is not built-in fusion |
| OpenClaw Search Fusion `d0dd0180024c` | Parallel direct providers, URL merging, custom scoring, provenance, partial outcomes | Closest small implementation of the proposed orchestration |
| Hermes Web Search Plus `053fcce7432c` | Opt-in research fanout; evidence observations and selected URL clusters | Useful budget/provenance model, with cancellation and selection caveats |
| paperfoot/search-cli `7df7b345cf40` | Concurrent providers, reciprocal rank fusion, deadline/cancellation metadata | Small reference for rank fusion and structured agent output |
| SearXNG `367fb6537c3a` + Vane `348feca3e378` | Metasearch backend followed by AI evidence filtering and answer generation | Clear separation of retrieval aggregation and synthesis |
| GPT Researcher `6f998577d547` | Every configured retriever runs for a subquery; providers sequential in inspected path, subqueries concurrent | Real multi-provider research without provider-parallel RRF |

### OpenClaw: distinguish core, backend, and ecosystem

The local OpenClaw checkout was clean at
`88a48ac42f4e6400bd3d06d7bdedf8de030c4696`. Its managed executor iterates candidates,
awaits one provider, and returns immediately on success. Explicit provider selection
disables automatic fallback. Cancellation takes precedence over trying another provider.
This is supported by the [actual executor](https://github.com/openclaw/openclaw/blob/88a48ac42f4e6400bd3d06d7bdedf8de030c4696/src/web-search/runtime-execution.ts#L26-L78),
not inferred from the provider list.

OpenClaw can still deliver metasearch through its bundled SearXNG integration. That
adapter sends one request to the configured instance; SearXNG performs upstream fanout.
The adapter preserves backend order and takes the first valid results up to `count`.
It drops engine identities, original ranks, and upstream scores when constructing its
output. See [selection](https://github.com/openclaw/openclaw/blob/88a48ac42f4e6400bd3d06d7bdedf8de030c4696/extensions/searxng/src/searxng-client.ts#L155-L181)
and [result projection](https://github.com/openclaw/openclaw/blob/88a48ac42f4e6400bd3d06d7bdedf8de030c4696/extensions/searxng/src/searxng-client.ts#L305-L325).

Useful ideas include provider-specific cache keys, cancellation precedence, output caps,
and distinct representations for search results and generated answers. The common cache
has expiry and size controls, while adapters own their HTTP deadlines; the managed
fallback loop itself does not establish a single deadline across every candidate.
See [shared cache helpers](https://github.com/openclaw/openclaw/blob/88a48ac42f4e6400bd3d06d7bdedf8de030c4696/src/agents/tools/web-shared.ts#L19-L82)
and [output normalization](https://github.com/openclaw/openclaw/blob/88a48ac42f4e6400bd3d06d7bdedf8de030c4696/src/agents/tools/web-search-output.ts#L21-L150).

Self-hosting SearXNG does not keep public-web query terms inside the local network:
upstream engines still receive them. It changes which intermediary operates the
aggregation. Do not adopt stronger privacy claims from adapter documentation without
examining the deployed upstream configuration.

### Hermes: native selection, SearXNG, and an opt-in community research mode

The local Hermes Agent checkout was clean at
`3eb9712180ec60191edfb9d072ddb28ffe427e4b`. The native tool resolves one provider and
calls its search method through a cache. A rotating keyless-provider ring and rescue
paths can try alternatives sequentially. Concurrent-request coalescing in the cache
avoids duplicate work; it is not provider fanout. See [tool dispatch](https://github.com/NousResearch/hermes-agent/blob/3eb9712180ec60191edfb9d072ddb28ffe427e4b/tools/web_tools.py#L268-L344),
[keyless failover](https://github.com/NousResearch/hermes-agent/blob/3eb9712180ec60191edfb9d072ddb28ffe427e4b/plugins/web/keyless_mcp.py#L317-L391),
and [cache](https://github.com/NousResearch/hermes-agent/blob/3eb9712180ec60191edfb9d072ddb28ffe427e4b/tools/web_result_cache.py#L80-L130).

Hermes also has a [SearXNG adapter](https://github.com/NousResearch/hermes-agent/blob/3eb9712180ec60191edfb9d072ddb28ffe427e4b/plugins/web/searxng/provider.py#L24-L39),
so external metasearch is available. It projects the upstream output into its normal
result fields, dropping engine-list provenance.

The community catalog pins [Hermes Web Search Plus](https://github.com/NousResearch/hermes-agent/blob/3eb9712180ec60191edfb9d072ddb28ffe427e4b/plugin-catalog/web-search-plus.yaml#L1-L8)
at `053fcce7432c58d7329ef556c971394c80040f98`. Its explicit `research` mode starts
concurrent provider tasks and supports partial results, request budgets, deadlines,
and early return after a quorum. Selecting its native `wsp` backend alone still uses
normal mode; research fanout is opt-in. See [research execution](https://github.com/robbyczgw-cla/hermes-web-search-plus/blob/053fcce7432c58d7329ef556c971394c80040f98/research.py#L100-L324)
and [native bridge](https://github.com/robbyczgw-cla/hermes-web-search-plus/blob/053fcce7432c58d7329ef556c971394c80040f98/native_backend.py#L141-L156).

Three details matter for inspiration:

- Default selection concatenates provider lists, removes normalized-URL duplicates, and
  stops at the result cap. This is not RRF. Its early normalization drops query strings,
  which can collapse different documents. An offline synthetic check with three successful
  providers, five distinct URLs each, and a final cap of five selected all five results
  from the first provider. This demonstrates selection behavior, not live search quality.
  See [merge function](https://github.com/robbyczgw-cla/hermes-web-search-plus/blob/053fcce7432c58d7329ef556c971394c80040f98/quality.py#L32-L60).
- The current v3 path separately retains all completed provider observations, including
  original URL, rank, attempt, and excerpt provenance. Selected URL clusters refer back
  to those observations. Therefore it would be wrong to claim that the system globally
  loses duplicate provenance. See [raw evidence retention](https://github.com/robbyczgw-cla/hermes-web-search-plus/blob/053fcce7432c58d7329ef556c971394c80040f98/search.py#L2015-L2029)
  and [observation projection](https://github.com/robbyczgw-cla/hermes-web-search-plus/blob/053fcce7432c58d7329ef556c971394c80040f98/runtime_v3.py#L298-L435).
- Returning at timeout/quorum does not cancel its daemon threads: upstream requests can
  continue until their own HTTP timeout. Bounded caller latency is not the same as
  bounded billable work. See the explicit [task contract](https://github.com/robbyczgw-cla/hermes-web-search-plus/blob/053fcce7432c58d7329ef556c971394c80040f98/daemon_tasks.py#L76-L87).

Its [benchmark contract](https://github.com/robbyczgw-cla/hermes-web-search-plus/blob/053fcce7432c58d7329ef556c971394c80040f98/docs/V3_BENCHMARKS.md#L1-L14)
focuses on operational and retrieval-output diagnostics. No controlled improvement in
final answer quality over the best individual provider was established by the inspected
material. The useful design is the distinction between raw observations and selected
evidence, not an assumption that fanout alone improves the final top results.

### OpenClaw Search Fusion: an external plugin with the proposed shape

[VACInc/openclaw-search-fusion](https://github.com/VACInc/openclaw-search-fusion) is a
separate project, not OpenClaw core. At revision
`d0dd0180024c481f89e54ae38d13adbfa8d504de`, it runs configured native providers in
parallel, collects settled outcomes, and combines successful responses. Provider
timings, failures, attempts, and partial outcomes are exposed, with a shared deadline
and abort propagation. See its [orchestrator](https://github.com/VACInc/openclaw-search-fusion/blob/d0dd0180024c481f89e54ae38d13adbfa8d504de/src/search-fusion.ts#L1133-L1359).

Its merger retains provider variants and original positions. Ranking is a custom
`merged-score-v1`, using variant scores, provider count, rank, and source adjustments;
it is not RRF. The provider-count bonus is named `corroborationBonus`, but it cannot
establish independent factual corroboration. Raw relevance scores from unrelated
providers are not automatically comparable. These are implementation heuristics, not
validated quality guarantees. See [merge and ranking](https://github.com/VACInc/openclaw-search-fusion/blob/d0dd0180024c481f89e54ae38d13adbfa8d504de/src/search-fusion.ts#L684-L898).

Borrow the orchestration and diagnostics concepts. Re-derive URL identity and ranking
rules for swift-claw; do not inherit empirical weights or stronger credibility claims.

### Search CLI: RRF with useful operational details and instructive defects

[paperfoot/search-cli](https://github.com/paperfoot/search-cli) uses Tokio tasks to query
providers concurrently. In ordinary modes, once sufficient unique results arrive, it
allows a 1.5-second grace period before cancelling remaining tasks. Its deep mode waits
subject to provider timeouts. It separates generated answers from fetchable URL results
and records provider contributions, failures, and cancellations.
See [execution](https://github.com/paperfoot/search-cli/blob/7df7b345cf4098c1f8b2fcf52e5aa096815a0268/src/engine.rs#L26-L225).

The fusion function sums reciprocal ranks with `k=60`, then truncates. However, equal
scores use insertion order, and provider buckets arrive in completion order; duplicate
text also keeps the first-arriving version. Thus the README's deterministic-ordering
claim is stronger than the complete implementation supports. URL normalization also
lowercases the entire URL, risking collisions between case-sensitive paths or query
values. See [fusion and normalization](https://github.com/paperfoot/search-cli/blob/7df7b345cf4098c1f8b2fcf52e5aa096815a0268/src/engine.rs#L232-L367).

The lesson is concrete: deterministic scores need deterministic tie-breaking and excerpt
selection too. Deadline-based collection can still change the candidate set between runs.

### SearXNG and Vane / Perplexica: metasearch below the agent

SearXNG runs engine searches in separate threads and joins them within a search timeout,
recording unresponsive engines. Its merger retains engine identities and positions.
Its scoring uses weighted reciprocal positions with an occurrence factor, rather than
standard RRF with a fixed `k=60`. See [fanout](https://github.com/searxng/searxng/blob/367fb6537c3a9fd6e54f707118a5a9e9d2252703/searx/search/__init__.py#L135-L180)
and [scoring](https://github.com/searxng/searxng/blob/367fb6537c3a9fd6e54f707118a5a9e9d2252703/searx/results.py#L17-L38).

Perplexica's repository now redirects to [Vane](https://github.com/ItzCrazyKns/Vane).
The inspected version calls SearXNG, then processes evidence for an LLM. Speed/balanced
modes filter and deduplicate using embeddings; quality mode uses model-assisted URL
selection and page reading. Its concurrent query calls should not be confused with
the engine fanout occurring inside SearXNG. See [SearXNG client](https://github.com/ItzCrazyKns/Vane/blob/348feca3e378fb4157b217724ed508dc707f853f/src/lib/searxng.ts#L21-L67)
and [evidence selection](https://github.com/ItzCrazyKns/Vane/blob/348feca3e378fb4157b217724ed508dc707f853f/src/lib/agents/search/researcher/actions/search/baseSearch.ts#L38-L176).

This is a strong architectural precedent for separating retrieval, evidence selection,
and answer generation. It does not prove that those particular embedding thresholds
are optimal. Hosting SearXNG also adds responsibility for upstream engine availability,
blocking, configuration, and deployment.

### GPT Researcher: multiple retrievers, but inspect the concurrency boundary

GPT Researcher accepts a comma-separated retriever list. At
`6f998577d547b1e54ec662dac63583aa11e3b84b`, the inspected research path executes each
non-MCP retriever for the same subquery, awaiting providers sequentially. It unions
exact URLs, removes already visited URLs, shuffles the candidate list, and proceeds to
content acquisition. There is no RRF in that path. Subqueries do run concurrently.
See [configuration](https://github.com/assafelovic/gpt-researcher/blob/6f998577d547b1e54ec662dac63583aa11e3b84b/gpt_researcher/config/config.py#L189-L202),
[provider loop](https://github.com/assafelovic/gpt-researcher/blob/6f998577d547b1e54ec662dac63583aa11e3b84b/gpt_researcher/skills/researcher.py#L803-L935),
and [subquery concurrency](https://github.com/assafelovic/gpt-researcher/blob/6f998577d547b1e54ec662dac63583aa11e3b84b/gpt_researcher/skills/researcher.py#L380-L398).

Its explicit distinction between preview snippets and content that does not require
scraping is useful: a long snippet is not proof that the agent has read the page.

## What the evidence actually says about quality

### Direct modern agent evidence: an auditable but inconclusive small experiment

[firish/webfetch](https://github.com/firish/webfetch) implements a local search, fetch,
ranking, and compression pipeline, including fusion across DuckDuckGo, Brave, Serper,
and Tavily. Its project-authored July 2026 experiment compares four-engine fusion with
DDG alone using the same agent loop and model on 50 SimpleQA questions. A separate set
of 27 recent-event questions reports 100% for both configurations. This is not independent
replication. See the [published experiment description](https://github.com/firish/webfetch/blob/3399799ee1377564020eaca29b813721101f5523/README.md#L187-L229).

We downloaded the [published per-question records](https://github.com/firish/webfetch/blob/3399799ee1377564020eaca29b813721101f5523/evals/results/e2e_eval_20260714_005531.json)
and recomputed the paired outcomes by question ID:

| Measure | Four-engine fusion | DDG alone |
|---|---:|---:|
| Correct answers | 46/50 (92%) | 42/50 (84%) |
| Published estimated cost per question | $0.0349 | $0.0259 |
| Published median task time | 54.4 s | 55.5 s |
| Questions answered without any search call | 9 | 8 |

Both configurations were correct on 42 questions and noncorrect on four. Four questions
improved with fusion; none regressed. **Our exact two-sided McNemar calculation gives
`p = 0.125`**, using the four discordant pairs. The +8 percentage-point estimate is
promising but does not establish an improvement at the conventional 5% significance
level. It also does not establish equivalence or no effect.

Three of the four gains changed `max turns exceeded` to correct; one changed an incorrect
answer to correct. These are agent-loop outcomes, not direct evidence of HTTP outage
recovery or improved retrieval recall. Estimated cost per question increased by about
35%. The calculation reuses the author's grades; we did not independently rejudge the
answers or rerun providers.

The [evaluation harness](https://github.com/firish/webfetch/blob/3399799ee1377564020eaca29b813721101f5523/evals/run_e2e_eval.py)
changes the search adapter within a common pipeline. However, the reported comparison
lacks each constituent provider under identical processing, the strongest constituent
baseline, a matched-spend single-provider alternative, and repeated trials. It cannot
attribute the difference specifically to RRF rather than a larger candidate pool, paid
provider access, or changed search trajectories. The richer fetch/rerank pipeline also
differs substantially from swift-claw's current snippet tool.

### Classical retrieval supports the mechanism, not a universal agent uplift

The original [RRF paper, Cormack et al., SIGIR 2009](https://cormack.uwaterloo.ca/cormack/cormacksigir09-rrf.pdf)
reports improved retrieval when combining ranked runs on TREC and LETOR. For example,
TREC Robust mean average precision is 0.3686 for RRF versus 0.3586 for the best individual
run. There are qualifications: on TREC 9 it beats the best automated run but not the
human-assisted run. These are archival retrieval metrics, not live provider APIs or
the accuracy of an LLM's final answer.

[An Analysis of Fusion Functions for Hybrid Retrieval](https://arxiv.org/abs/2210.11934)
provides a useful counterweight: in its lexical/dense retrieval setting, RRF is sensitive
to parameters and tuned score combinations outperform it. That setting is also indirect;
its weights should not be imported into unrelated web APIs. Together these studies justify
RRF as a baseline to test, not a universal best algorithm.

### Different engines expose different material; different is not necessarily better

A [2022 source-distribution study](https://arxiv.org/abs/2207.07330) compares 3,537
trending queries across engines. It finds substantial differences and some highly
correlated engine pairs. Its overlap metric concerns root domains, not independent
facts or exact-page identity; its historical search-interface results do not establish
current API complementarity. The supported inference is that provider diversity is a
plausible source of additional candidates, to be measured on the intended workload.

The vendor-authored [NEEDLE benchmark](https://keenableai.github.io/needle/) is useful
for relevant-result uniqueness and overlap analysis. Its pooled `ultimate` row ranks
using relevance labels or known answers: it is an **oracle ceiling**, not a deployable
fusion algorithm whose agent benefit has been measured. Its overlap heuristic can suggest
shared upstream dependence, but cannot prove commercial index relationships.

### More evidence can make the reader worse

[InfoDeepSeek](https://arxiv.org/html/2505.15872v2) evaluates live agentic information
seeking on 245 challenging questions and documents retrieval interference: some answers
that were correct without retrieval become wrong after browsing. It also distinguishes
finding evidence from selecting compact, useful evidence. It does not establish that
multi-provider fusion causes this effect; it demonstrates why adding results cannot be
assumed to improve final answers.

[Making Retrieval-Augmented Language Models Robust to Irrelevant Context](https://proceedings.iclr.cc/paper_files/paper/2024/hash/8011b23e1dc3f57e1b6211ccad498919-Abstract-Conference.html)
similarly studies irrelevant-context failures in QA. [FeB4RAG](https://arxiv.org/abs/2402.11891)
separates resource selection and merging in federated retrieval, using simulated resources
from benchmark collections. Both inform design and evaluation, but neither is a live
Exa-plus-Perplexity agent ablation.

### Existing provider leaderboards answer a different question

[Artificial Analysis's methodology](https://artificialanalysis.ai/methodology/search-api)
holds an agent environment fixed while changing the search provider. It can inform the
individual baselines. It does not show whether its top providers combine well. Search
API errors classified as fatal, including 429s, 5xx responses, and timeouts, are retried
until success, so the published quality comparison is not an availability benchmark.

[OpenBenchmarks' coding-agent evaluation](https://openbenchmarks.com/web-search-for-coding-agents)
separates search-only from search-plus-fetch across 100 tasks with repeated runs. That
distinction matters: changing page acquisition can change the outcome independently
of search aggregation. Neither board is a controlled single-versus-fused-provider test.

The evidence therefore supports three different confidence levels: **high confidence
that the architecture exists; credible evidence that rank fusion can improve retrieval;
limited direct evidence for modern agents, and no measured result yet for swift-claw.**

## Why combining providers can help — and why it can fail

The following are engineering inferences, not measured gains for swift-claw.

**Coverage.** A second provider can expose a page absent from the first provider's
candidate set, including obscure documentation, regional material, or newly indexed
content. But additional URLs are only useful if they contain relevant evidence and
survive final selection. Low overlap alone is not a quality metric.

**Ranking.** Fusion can promote a useful page that several providers rank moderately
well. It can also bury a unique authoritative page beneath repeatedly discovered popular
pages. Providers may share upstream indexes; several API brands need not represent
independent retrieval systems.

**Availability.** Accepting partial success can avoid a complete tool failure. This
advantage must be measured separately from relevance. Shared network, index, quota, or
aggregation dependencies can make failures correlated. A successful HTTP response with
no useful evidence is a separate outcome from an outage.

**Cost and latency.** Parallel search costs roughly the sum of its upstream calls,
including applicable retries and extraction. Waiting for all providers takes roughly
the slowest completion time plus merge overhead, not the sum of their durations.
An earlier return reduces waiting but can remove the slow provider's unique evidence.
Cancellation cannot refund work already accepted or billed remotely.

**Context quality.** Forwarding every result expands input tokens, duplicates snippets,
and increases opportunities for irrelevant or malicious material to distract the model.
Select within a fixed final evidence budget. Source reputation, agreement, and actual
support for a claim are different properties.

### A small RRF example reveals an important tradeoff

For document `d`, ordinary reciprocal rank fusion uses:

```text
score(d) = sum over providers that returned d of 1 / (k + rank_provider(d))
```

With `k=60`, a unique first-ranked page receives `1/61 ≈ 0.0164`, while a page ranked
tenth by two providers receives `2/70 ≈ 0.0286`. The repeated page wins even if it is
less useful for the task. This is arithmetic, not a benchmark result.

RRF avoids having to calibrate unrelated provider scores. It does not establish truth,
relevance, index independence, or an optimal tradeoff between agreement and novelty.
Count each provider once per canonical page, define stable ties, preserve each original
rank, and evaluate the effect of the final cutoff. A more complicated reranker should
be earned by measured failures of a simpler baseline.

## An experiment that would answer the question for swift-claw

### Compare the right alternatives

| Arm | Purpose |
|---|---|
| A: current Exa search | Preserve the actual baseline |
| B: second provider alone | Determine whether simply switching is sufficient |
| C: Exa + second provider, same query, fusion | Measure the proposed feature |
| D: Exa with two query formulations | Compare provider diversity with query diversity at comparable call budget |
| E: single provider with fallback or conditional expansion | Measure a cheaper recovery/escalation strategy |

Start with a small replayable retrieval pilot, then an end-to-end task evaluation.
Exa plus Perplexity Search is a reasonable candidate pair because Perplexity exposes a
result-oriented search API, distinct from answer generation. Exa plus Brave is a useful
alternative hypothesis because Brave documents its own index. Neither pairing is
proven complementary by that fact alone. Measure marginal useful evidence instead of
choosing two providers solely from their individual leaderboard positions.
See [Perplexity Search](https://docs.perplexity.ai/docs/search/quickstart)
and [Brave Search API](https://brave.com/search/api/).

### Keep the comparison controlled

Use the same answer model/version, prompts, final result count, context budget, page
reader, extraction limits, and maximum task budget. Match language, location, freshness,
and domain restrictions where supported; record unsupported filters. Include both an
equal-output-budget comparison and an equal-dollar/call-budget comparison. If exact
cost matching is impossible, report the quality/cost curve rather than claiming a fair
single-number winner.

A practical initial set is 100–150 questions reflecting owner workloads: coding and
official documentation, current information, obscure facts, Russian/English and local
sources, and multi-hop research. This is a proposed pilot size, not a statistical
guarantee. Reserve development questions for tuning and hold out evaluation questions.
Repeat stochastic agent runs, randomize/interleave provider order in the same time
window, and retain timestamped responses when service terms allow it.

Include a no-search calibration baseline and label tasks solved without calling search.
Keep public benchmark answer dumps out of the evidence pool; otherwise retrieving a
leaked answer can be mistaken for finding the underlying source. Report these exclusions
and calibration outcomes separately from the main grounded-task comparison.

Separate two experiments: replay identical captured query/result sets to compare
fusion algorithms; run the full live agent to assess changes in follow-up queries and
task completion. They answer different questions. Do not silently remove rate limits,
timeouts, or malformed responses from the practical availability evaluation.

### Measure evidence, task success, and resources

- Grounded task success: correct answer or task completion, with citations that support
  the material claims. Blindly review disagreements and a sample of agreements.
- Marginal useful evidence from the second provider: pages or facts absent from the
  first output that actually help complete the task; unique URLs alone do not count.
- Relevant evidence within the final budget; use pooled human judgments and acknowledge
  incomplete relevance labels instead of claiming recall over the entire web.
- URL/domain overlap, redundant content, unique primary sources, and failed page reads.
- Median and tail latency, partial/all-failed rates, deadline cancellations, and remaining
  work after the caller stops waiting.
- Search, extraction, and model costs together, plus actual upstream request count.
  Report cost per grounded success as total run cost divided by successful tasks, including
  spending on failures.

Use paired uncertainty estimates by question and retain per-task outcomes. Select a
minimum worthwhile improvement and acceptable cost/latency increase before seeing the
held-out results. A small inconclusive pilot warrants further evaluation, not a claim
that either architecture is universally superior.

## Implementation direction if the experiment supports it

At swift-claw revision `5a36573e695f475a4c84d259870e754072eeb7b2`,
`SearchProviding.search(query:count:)` returns only title/URL/snippet values. Exa is its
sole implementation. `WebSearchTool` already provides one model-facing entry point,
count limits, an output cap, a 15-second timeout, and untrusted-content marking.
See [search contract](../../Sources/ClawCore/Domain/Tools/ToolContracts.swift),
[Exa adapter](../../Sources/ClawTools/Search/ExaSearchProvider.swift), and
[web search tool](../../Sources/ClawTools/Tools/WebSearchTool.swift).

Keep the seam/value types in `ClawCore`, provider adapters and aggregation in `ClawTools`,
and owner-selected composition in `clawd`. A composite provider can preserve the single
tool interface, but the current array-only result contract cannot fully express partial
provider outcomes or provenance. Make the smallest explicit contract change that covers
those requirements; do not hide diagnostics inside snippets.

The candidate pipeline is:

```text
validated query + fixed budget
    → selected provider calls in parallel
    → normalized observations, ranks, and provider outcomes
    → conservative URL grouping and rank fusion
    → final result/context cap
    → existing agent reads sources and answers with citations
```

Preserve the following boundaries:

1. **One total budget.** Bound fanout, per-provider response size, retries, and total
   deadline. Keep cancellation attached to real network tasks. One model tool call must
   not disguise unbounded paid requests.
2. **Conservative identity.** Retain original citable URLs and query parameters with
   possible meaning. Do not lowercase paths, drop all queries, or treat retrieval
   deduplication as an authorization/SSRF canonicalization rule.
3. **Explicit provenance.** Retain provider identity, original position, observed URL,
   and available excerpt provenance. Multiple providers finding a page is one source.
   Syndicated pages on different domains can still be one underlying account.
4. **Honest outcomes.** Distinguish full success, partial success, successful empty
   results, all failures, and caller cancellation. Sanitize diagnostics and redact every
   loaded search credential.
5. **Owner-controlled egress.** Query validation applies before fanout. Provider choices
   and endpoints belong to trusted configuration. Adding recipients expands disclosure
   of queries and changes the deployment trust boundary.
6. **Separate search and reading.** Preserve `web_fetch`'s existing security boundary.
   Neither URL agreement nor snippet length proves a page was fetched or supports a claim.

The existing normative wording describes one owner-pinned search endpoint, and the policy
fingerprint records only `searchEndpointPresent`. Multiple recipients require an explicit
specification and a credential-free identity for the selected provider/endpoint set.
Search API spending also needs its own bounded/accounted treatment; the existing LLM
budget must not be represented as automatically accounting for search charges.
See [accepted architecture](../ARCHITECTURE.md) and
[policy fingerprint](../../Sources/ClawCore/Domain/Policy/PolicyFingerprint.swift).

No implementation contract has been changed by this report. If issue #228 proceeds,
update normative architecture and the affected public configuration documents in the
implementation, following the repository's existing review and testing requirements.

## Supplementary research

The user also supplied a [Claude research report](multi-provider-web-search-research-claude-2026-09-19.md),
preserved unchanged. A [separate review](multi-provider-web-search-research-claude-review-2026-09-19.md)
identifies useful alternative strategies and checks consequential claims against primary
sources. Its recommendations are research hypotheses, not accepted implementation requirements.

## Research scope and limits

The audit traced execution paths, not just README feature lists. The user's OpenClaw and
Hermes repositories were not modified. Public projects were inspected at the revisions
listed above; no packages, plugins, daemons, or paid search integrations were installed.
One mocked, network-free Web Search Plus selection check and arithmetic on published
webfetch records were performed. Published measurements are attributed to their authors;
they are not our own live production results. These research documents do not change
production code or normative architecture.

The report intentionally avoids transferring old price tables, provider rankings, or
free-tier assumptions into a design decision. Those can change and do not establish
the marginal value of a second provider. The unresolved question is empirical:
**does the second provider supply enough useful, selected evidence to improve this
agent's outcomes under the same practical resource limits?**
