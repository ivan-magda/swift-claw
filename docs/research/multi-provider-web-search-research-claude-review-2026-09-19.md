# Review of the supplementary Claude research on multi-provider web search

Reviewed: **19 September 2026**. Related proposal: [issue #228](https://github.com/ivan-magda/swift-claw/issues/228).

The user supplied the [Claude report](multi-provider-web-search-research-claude-2026-09-19.md)
as a second analysis. The archived file preserves its original Russian text byte for
byte; this review supplies corrections separately. Original SHA-256:
`908cc2ab832e71dcb18af4f9faba849bbd33ed1487742ca7b3782f5385037200`.
See also the [implementation and evidence audit](multi-provider-web-search-research-2026-09-19.md).

## Assessment

**Useful as a list of alternatives and evaluation hypotheses; insufficient as a verified
basis for numerical promises, provider selection, or an implementation decision.**

Its strongest contribution is emphasizing cheaper controls: better use of the current
provider, query variation, fallback, and conditional expansion. It also correctly asks
for representative Russian-language tasks, marginal relevant evidence, citation quality,
and latency/cost measurements. These ideas complement the main research plan.

However, the attachment contains no linked bibliography or per-claim source URLs.
Several consequential statements are too categorical, misclassify implementations,
or do not match the cited research. Agreement between two generated reports is not
independent empirical validation, particularly when they draw on the same papers.

## Findings that need correction or qualification

### 1. Claimed RAG-Fusion accuracy gains are not in the cited paper

The report repeatedly attributes an 8–10% accuracy improvement and 30–40% completeness
improvement to RAG-Fusion. The cited [arXiv paper, version 2](https://arxiv.org/html/2402.03367v2)
does not report those percentages. It describes the author's manual assessment of
examples in an Infineon product-document setting. Its quantitative timing comparison
is not an answer-accuracy benchmark. Do not carry these numbers into issue acceptance
criteria or expected gains for Exa query expansion.

The subsequent [RAGElo evaluation](https://ceur-ws.org/Vol-3752/paper6.pdf) finds increased
completeness but decreased precision, and does not conclude that RAG-Fusion universally
produces better answers. It concerns an enterprise corpus, not multiple public-web APIs.
Query expansion is a useful experimental arm, not an established superior intermediate step.

### 2. Absence of direct evidence is stated too strongly

No broadly convincing, independently replicated modern agent result was found in our
review. That is narrower than saying that no direct experiment exists. The public
[webfetch records](https://github.com/firish/webfetch/blob/3399799ee1377564020eaca29b813721101f5523/evals/results/e2e_eval_20260714_005531.json)
include a direct fusion-versus-DDG comparison: 46/50 versus 42/50 correct, with four
discordant pairs. Our paired recalculation gives exact two-sided McNemar `p=0.125`.
This is weak, project-authored evidence with missing controls, not no evidence at all.
The main report explains the distinction and does not claim a swift-claw improvement.

### 3. Sequential provider calls are not necessarily provider switching

The attachment classifies GPT Researcher as switching rather than combining results.
At the inspected revision, its [provider loop](https://github.com/assafelovic/gpt-researcher/blob/6f998577d547b1e54ec662dac63583aa11e3b84b/gpt_researcher/skills/researcher.py#L803-L935)
calls each configured non-MCP retriever for a subquery and unions their URLs.
Those provider calls are sequential and there is no RRF in this path, but it is still
multi-provider retrieval. Concurrency, aggregation, and ranking fusion are separate axes.

The broader claim that industry generally avoids fusion is not established by a small
project sample or assumptions about closed products. Our source audit also found
OpenClaw Search Fusion, Hermes Web Search Plus, and search-cli. They establish feasibility,
not industry-wide prevalence or an accuracy advantage.

### 4. The Perplexity objection addresses a different API

The attachment partly discounts Exa + Perplexity by discussing Sonar. Issue #228 already
explicitly proposes [Perplexity Search API](https://docs.perplexity.ai/docs/search/quickstart),
separate from Sonar. An objection to generated answers does not disqualify the Search API.
Compare its marginal useful evidence with Brave, Serper, or another candidate empirically.

### 5. Similar single-provider scores do not establish little fusion headroom

The report describes an Artificial Analysis ceiling around 75 and argues that one strong
provider already captures almost all the gain. The [leaderboard inspected on this review date](https://artificialanalysis.ai/agents/search-api)
shows Perplexity Search medium at 80, Octen highlights at 77, and Exa auto at 74.
The cited snapshot is incomplete or outdated relative to this page.

More fundamentally, similar aggregate scores can hide different per-question failures.
They do not measure the overlap of useful evidence or the attainable gain from combining
providers. Conversely, a higher individual score does not prove that a provider is the
best complement to Exa. This conclusion requires paired outcomes, not leaderboard proximity.

### 6. Some proposed Exa improvements are already the baseline

The current [Exa adapter](../../Sources/ClawTools/Search/ExaSearchProvider.swift) requests
`contents.highlights: true` and omits `type`; the current [API reference](https://exa.ai/docs/reference/search)
documents `auto` as the default. Therefore simply enabling highlights and auto would
not implement a new improvement over current swift-claw behavior.

Exa's [content-freshness documentation](https://exa.ai/docs/contents/quickstart#content-freshness)
defines `maxAgeHours` as the permitted age of extracted/cached page content. It can
trigger a fresh fetch of a URL. It does not guarantee discovery of newly published pages
or repair gaps in index coverage. Treat discovery freshness and fetched-content freshness
as different measurements. Generated summaries are also different from source excerpts.

### 7. Prices and provider-language claims require fresh verification

The attachment's 20,000 free Exa searches per month conflicts with the
[pricing documentation inspected on 19 September 2026](https://exa.ai/docs/admin/pricing),
which describes $20 of initial credits and $10 of recurring monthly credits. Do not use
the imported free-tier assumption for the budget decision.

Statements that Exa is generally weak on Russian content, no AI search APIs optimize
Russian morphology, or a particular alternative is the best complement are hypotheses
here. The attachment does not provide enough reproducible evidence to establish them.
Its quoted vendor freshness scores, market events, and other price tables have not all
been revalidated in this targeted review. They remain background leads, not adopted facts.

### 8. Context-noise evidence is useful but does not mandate a reranker

The reported greater-than-30% loss in the 20-document Lost in the Middle example needs
precision. For GPT-3.5-Turbo in [Table 6](https://cs.stanford.edu/~nfliu/papers/lost-in-the-middle.tacl2023.pdf),
moving the relevant document from position 1 to position 10 changes accuracy from 75.8%
to 53.8%: 22 percentage points, about 29% relative. The positional effect is real, but
this is a particular older-model experiment, not a universal modern-agent penalty.

The cited [The Powerless Noise](https://arxiv.org/abs/2607.03615) is real and supports
caution about interpreting noise gains: the reproduced effect is sensitive to experimental
settings. Neither paper proves that a cross-encoder or LLM reranker is mandatory after
web-provider fusion. Deterministic rank fusion with a fixed final evidence budget is a
legitimate baseline; an additional reranker should justify its own cost and benefit.

## How this changes the decision

Keep the main recommendation: retain the current Exa baseline and evaluate a bounded,
opt-in two-provider alternative. Add meaningful Exa tuning and query variation to the
comparison when they actually differ from the existing request. Measure fallback
separately: improving outage recovery does not demonstrate better successful retrieval.

The Claude report's proposed 15–20% unique relevant results, five-percentage-point answer
gain, and 30% latency allowance are suggested product thresholds, not standards derived
from the literature. Choose thresholds before held-out evaluation, specify the denominator
for marginal relevance, and report paired uncertainty. A 50–150-question pilot does not
automatically have enough power to establish a five-point improvement.

Fallback on an error, fallback on a successful empty response, and escalation after
apparently weak evidence need different definitions. Empty results can be legitimate;
low confidence is not a reliable control signal until its meaning and cost are evaluated.
Query fanout also spends additional calls and can add latency even with one provider.

Do not silently replace issue #228's concurrent aggregation requirement with fallback.
Fallback is an alternative or a separately scoped increment, not completion of that issue.
The import and review do not change the implementation or default policy.

This review verified selected consequential claims; it is not an exhaustive validation
of every citation, corporate event, price, or vendor benchmark in the attachment.
