# Default web search backend for swift-claw

## Recommendation

**Use Exa as the default `SearchProviding` backend.** It best matches the stated priority order: its official product/docs explicitly position the API as a search service for **AI agents**, its public API contract is straightforward and stable, its **free tier is large enough to cover the full stated workload indefinitely** at 50–200 queries/day, and its official materials state that Exa has **its own crawler and search solution** rather than merely reselling another search engine’s index. The main tradeoff is that Exa’s search endpoint is **`POST /search`** rather than the ideal one-`GET`-with-JSON shape, but that is a smaller compromise than Brave’s restrictive no-cache / no-training terms, Tavily’s smaller free tier and broader AI-data-retention terms, or SearXNG’s operational and upstream-ToS burden. citeturn18view3turn18view1turn18view4turn18view0turn18view2

**Runner-up:** if you value **GET-only simplicity** above generous monthly free usage, **Brave Search API** is the cleanest wire contract of the hosted options and has a strong independent index. I would not make it the default for swift-claw because its recurring free credit only covers about **1,000 search requests/month** and its Terms prohibit storing/caching search results except transiently and prohibit using search results to train or improve AI models. Those restrictions are manageable for a read-only transient tool, but they are still materially narrower than Exa’s public contract. citeturn6search0turn6search1turn39view0turn40view0

## Comparison table

| Candidate | Pricing and free tier | ToS position on automated or LLM-agent use | Wire contract | Key provisioning | Index quality and independence | SearXNG-style operational burden | Source set |
|---|---|---|---|---|---|---|---|
| **Exa** | **20,000 requests/month free**; paid Search is **$7 per 1,000 requests**; default `/search` limit **10 QPS**. Public pricing presents the free tier as recurring monthly, with no public time limit stated. citeturn18view3turn18view0 | Official pages explicitly market it for **agents** and “search built for your AI.” Public ToS grants API use subject to docs; I did **not** find a public clause banning feeding search results into an LLM. Caveat: Exa’s ToS grants Exa a broad license to access/use/cache/store your **User Input and Output** to provide and improve services, and Exa may terminate API access at any time. citeturn18view3turn38view9turn18view2turn19view5 | **`POST https://api.exa.ai/search`**; auth via **`x-api-key`** header or `Authorization: Bearer`; JSON body includes `query`, `numResults`, `includeDomains`, `excludeDomains`, date filters, `userLocation`, `moderation`, and `contents` options; result fields include `results[].title`, `results[].url`, and optional `results[].highlights[]`, `results[].summary`, `results[].text`; documented request-level errors include **400/401/422/429/500**. citeturn18view1turn36view0turn37view0turn37view2turn16search0 | Official docs say to get the key from the **Exa Dashboard**; public docs do **not** say a credit card is required for the free tier, and I found no primary-source statement requiring one. citeturn38search1turn38search3turn20search0 | Official FAQ says Exa has **its own crawler** and **its own search solution**; docs also expose freshness controls such as `maxAgeHours` and live crawling. citeturn18view4turn18view5turn17search4 | Hosted API, so low burden. | citeturn18view3turn18view1turn18view4turn18view0turn18view2 |
| **Brave Search API** | Search plan is **$5 per 1,000 requests** with **free recurring $5 credits every month**, which implies roughly **1,000 free search requests/month** on the Search plan; capacity is **50 requests/second**. Public docs describe monthly credits as recurring and automatically applied. citeturn6search0 | Official docs and pricing clearly target **“chatbots & agents.”** But Brave’s ToS is materially restrictive: you may not **store/cache** search results except transiently, may not create derivative works of search results, may not redistribute or resell them, and may not use them to **train/fine-tune/benchmark/improve** AI models or services. Help docs also say retaining any data from the API is prohibited unless Brave approves otherwise. citeturn6search0turn39view0turn6search2 | **`GET https://api.search.brave.com/res/v1/web/search`**; auth via **`X-Subscription-Token`** header; query params include `q`, `count`, `country`, `search_lang`, `ui_lang`, `safesearch`, `freshness`; result fields for a basic search are `web.results[].title`, `web.results[].url`, `web.results[].description`; docs describe 429 handling via rate-limit headers and `X-RateLimit-*` windows. citeturn6search1turn5view0turn40view0 | Official quickstart requires account creation, plan subscription, and entering a **credit card** before generating an API key; help page says the card is required as an anti-fraud measure and for overage billing. citeturn6search1turn6search2 | Official FAQ says Brave Search API is powered by **Brave Search**, a **fully independent search engine**, with its own crawler and millions of pages fetched every day. citeturn6search2 | Hosted API, so low burden. | citeturn6search0turn6search1turn6search2turn5view0turn39view0turn40view0 |
| **Tavily** | Free plan gives **1,000 credits/month** with **no credit card required**. Search cost is **1 credit** for `basic` / `fast` / `ultra-fast`, **2 credits** for `advanced`, and PAYG is **$0.008/credit**. That works out to **$8 per 1,000 basic queries** or **$16 per 1,000 advanced queries**. Standard rate limits are **100 RPM** for development keys and **1,000 RPM** for production keys. citeturn8view1turn8view3turn8view4turn9search0turn10view0 | Tavily’s docs openly position Search as built for **LLMs and AI agents**. Public terms do not prohibit sending results to an LLM. However, the Platform Terms are materially less privacy-clean than Exa’s for a personal assistant: Tavily and third-party AI providers may use **Customer Input and Output** for **training/improving** models, and free-trial services may be restricted or discontinued at Tavily’s discretion. Tavily also restricts resale and competitive use. citeturn15search1turn14view0turn14view2turn14view5turn8view2 | **`POST https://api.tavily.com/search`**; auth via **`Authorization: Bearer tvly-...`**; body includes `query`, `search_depth`, `max_results`, `topic`, `time_range`, dates, `country`, `safe_search`; result fields are `results[].title`, `results[].url`, `results[].content`; documented statuses include **200/400/401/429/432/433/500** and rate-limit handling uses **429 + `retry-after`**. `safe_search` is **enterprise-only**. citeturn10view0turn12view0turn9search0 | Sign up in Tavily platform, create/copy API key from dashboard; official docs say **no credit card required** for the free tier. citeturn8view4turn8view3turn8view6 | Official docs say **Tavily Search has a crawler** that discovers pages and **indexes** content. What Tavily does **not** publicly document, as clearly as Brave or Exa, is the breadth/independence of that index for general web search. Quality is positioned as “real-time” and AI-focused, but the public docs emphasize search-plus-scraping more than a large stand-alone public web index. citeturn15search0turn15search1turn9search7 | Hosted API, so low burden. | citeturn8view1turn8view3turn8view4turn9search0turn10view0turn12view0turn14view0turn15search0 |
| **SearXNG self-hosted** | No API fee from SearXNG itself; no built-in free-tier cap. Your real limits come from your **hosting**, your **enabled engines**, and upstream anti-bot enforcement. citeturn29search1turn24view0turn24view1 | SearXNG itself is open-source software and its docs explicitly contemplate **single-user private instances**. There is no SearXNG platform ToS barring an AI assistant. But SearXNG forwards queries to **external search services**, so the effective legal/operational risk lives in the ToS and anti-abuse rules of those upstream engines. citeturn23view3turn24view0turn29search1 | Simple HTTP interface: **`GET /search`** or **`POST /search`**, with `format=json`; params include `q`, `categories`, `language`, `pageno`, `time_range`, `safesearch`. Search API docs note **403** if requested formats are disabled. The JSON/result model is stable enough for `results[].title`, `results[].url`, `results[].content`, but exact result behavior varies by enabled engines. citeturn24view0turn24view2turn26search7 | Self-provisioned. No API-key flow is built into the search endpoint docs; typical protection is network isolation / VPN / reverse proxy rather than a provider-side key issuance flow. citeturn24view0turn23view3 | SearXNG is explicitly a **metasearch engine** aggregating results from various external services and databases, not an independent general-web index of its own. citeturn29search1 | Highest burden of the set. Official docs recommend container/install-script deployment; a robust public-facing install needs **limiter + Valkey** to avoid bots, CAPTCHAs, and upstream bans. Engine errors lead to suspensions such as **1 hour** for “Too Many Requests,” and the project is a **rolling release** rather than a tagged-releases workflow, which is a maintenance signal. Public instances can lose result quality when external services CAPTCHA or ban the instance IP. citeturn23view5turn24view1turn24view2turn22search2turn29search3turn23view2 | citeturn29search1turn24view0turn24view1turn24view2turn23view2turn23view5turn29search3 |

**Notable newcomer checked:** **Firecrawl Search** is worth watching, especially because its official docs explicitly target AI agents and its free plan is unusually generous in credit terms. But I would **not** promote it over Exa here because its public docs do **not** document index provenance / independence as clearly as Exa or Brave, and its pricing is **credit-per-result-plan** rather than a simple pay-as-you-go per-query schedule, which makes it a less natural “default metadata search backend” for this specific `SearchProviding` abstraction. citeturn34view0turn32view1turn35view0

## Why Exa is the best default for swift-claw

The deciding fact is the workload. Swift-claw expects roughly **50–200 queries/day**, or about **1,500–6,000 queries/month**. Exa’s official free tier is **20,000 requests/month**, so it covers the whole stated daily-driver range without any paid plan. Brave’s recurring free credit only covers about **1,000 search requests/month**, and Tavily’s recurring free tier covers only **1,000 basic** or **500 advanced** searches/month. SearXNG avoids per-query fees, but shifts the cost into maintenance and upstream fragility rather than actually removing cost/risk. citeturn18view3turn6search0turn8view1turn10view0turn29search1

On the highest-priority criterion, **ToS-clean automated/LLM use**, Exa’s public materials are the least self-defeating fit for a personal assistant. Exa explicitly markets the product for **AI**, provides agent-specific docs, and its public Terms grant API use without the specific no-cache / no-training prohibitions that Brave imposes on search results. Tavily also targets agents, but its terms are materially less attractive for a privacy-sensitive personal daemon because Tavily and third-party providers may use Customer Input and Output for training/improvement. Brave is the opposite problem: stronger privacy marketing, but a much tighter license over the returned search results themselves. citeturn38view9turn18view2turn15search1turn14view0turn14view5turn39view0

Exa also scores well on the independence criterion. Its official FAQ says Exa has **its own crawler**, and its security/FAQ materials say Exa has **its own search solution**. Brave also scores highly here, and if the decision were only “best independent index with simple GET,” Brave would be very hard to beat. But once the permanent free-tier coverage is weighted properly, Exa comes out ahead for this specific single-user assistant. citeturn18view4turn6search2

The one criterion where Exa is merely “good” rather than “best” is wire simplicity. It is a keyed JSON API, but the request is a **POST with JSON body**, not a single GET. In practice, for a Swift daemon implementing an internal `SearchProviding` protocol, that difference is small: the auth is a single header, the endpoint is single-purpose, the JSON schema is clean, and the exact field mapping to `{title, url, snippet}` is straightforward. citeturn18view1turn36view0

## Candidate notes that matter for a default choice

### Brave Search API

Brave is the cleanest **search-shaped** API here. It is a straightforward GET endpoint with a header token and a very conventional response model, and Brave’s official materials are unusually clear that the index is independent and that the API is intended for agents. If swift-claw needed a backend with the least integration friction and you were comfortable with transient-only use of results, Brave would be an excellent choice. citeturn6search0turn6search1turn5view0turn6search2

The problem is not quality or protocol; it is the **license on results**. Brave’s Terms bar storing or caching search results except transiently, bar creating derivative works of search results, and bar using search results to train or improve AI models. For a private Telegram-controlled assistant that only performs **read-only live search** and does not retain results, that may still be acceptable. But as a **default** backend, those terms are more brittle than Exa’s, especially if swift-claw might later add conveniences like short-lived local caching, deduping previous results, or analytics over prior answers. citeturn39view0turn6search2

### Tavily

Tavily is purpose-built for LLM and agent retrieval and has a good developer experience. Its search schema is easy to use, it supports optional answer generation, domain filters, date filters, and a simple `results[].title / url / content` contract. For an agent pipeline that wants search plus extracted content in one shot, Tavily is quite attractive. citeturn10view0turn12view0turn15search1

I would not make it the default for swift-claw because two issues line up against your priority order. First, the free plan is too small for the expected steady-state workload. Second, Tavily’s Terms are much more permissive **for Tavily** than for you: they allow Tavily and AI providers to use submitted input/output to improve models, and Tavily reserves wide discretion around free-trial availability. That may be perfectly fine for many applications, but it is not the strongest fit for a single-owner personal assistant that is trying to stay conservative on trust dependencies. citeturn8view1turn9search0turn14view0turn14view5turn8view2

### SearXNG

SearXNG is best understood as a **control-maximizing** option, not a convenience-maximizing one. Official docs explicitly say single-user private instances are a valid model, and the wire contract is easy: `/search?q=...&format=json` yields a stable-enough result structure for `title`, `url`, and `content`. If your top goal were “no third-party hosted search provider at all,” SearXNG would be the obvious answer. citeturn23view3turn24view0turn26search7

But SearXNG is a metasearch engine, so in practice it imports the fragility of upstream engines. The project’s own docs center **limiter**, **Valkey**, **CAPTCHA avoidance**, engine suspension on 429s, and the consequences of abused/public instances getting blocked or returning fewer results. That is all manageable, especially at single-user volume, but it is still more operational surface than a hosted API. Under your stated priority order, a hosted service should win unless ToS or cost force self-hosting. Here, they do not. citeturn24view1turn24view2turn23view2turn22search2turn29search3

## Recommended integration contract for Exa

### Complete example request

```http
POST https://api.exa.ai/search
x-api-key: YOUR_EXA_API_KEY
Content-Type: application/json

{
  "query": "swift structured concurrency actor isolation",
  "type": "fast",
  "numResults": 5,
  "userLocation": "FI",
  "moderation": true,
  "contents": {
    "highlights": true
  }
}
```

The fields that matter for a minimal `SearchProviding` implementation are:

- **title** → `results[].title`
- **url** → `results[].url`
- **snippet** → prefer `results[].highlights[0]`; fallback to `results[].summary`; fallback to `results[].text` if highlights are absent. The official search docs/examples show all three content-bearing fields on a search result when content extraction is requested. citeturn18view1turn36view0turn36view1turn36view2turn37view0

### Trimmed example response

```json
{
  "results": [
    {
      "title": "A Comprehensive Overview of Large Language Models",
      "url": "https://arxiv.org/pdf/2307.06435.pdf",
      "text": "Abstract Large Language Models (LLMs) have recently demonstrated remarkable capabilities...",
      "highlights": [
        "Such requirements have limited their adoption..."
      ],
      "summary": "This overview paper on Large Language Models (LLMs) highlights key developments..."
    }
  ]
}
```

For swift-claw’s current abstraction, the parser can safely extract:

```text
title   = results[i].title
url     = results[i].url
snippet = results[i].highlights[0] ?? results[i].summary ?? results[i].text
```

That mapping is fully grounded in Exa’s published response example and field docs. citeturn18view1turn36view0turn36view1turn36view2

## Source register

All URLs below were accessed on **2026-07-03** in **Europe/Helsinki** time.

### Exa

```text
https://exa.ai/pricing
https://exa.ai/docs/reference/search
https://exa.ai/docs/reference/rate-limits
https://exa.ai/docs/reference/faqs
https://exa.ai/docs/reference/livecrawling-contents
https://exa.ai/docs/reference/quickstart
https://exa.ai/assets/Exa_Labs_Terms_of_Service.pdf
https://dashboard.exa.ai/
```

### Brave Search API

```text
https://api-dashboard.search.brave.com/documentation/pricing
https://api-dashboard.search.brave.com/documentation/quickstart
https://api-dashboard.search.brave.com/api-reference/web/search/get
https://api-dashboard.search.brave.com/documentation/guides/rate-limiting
https://api-dashboard.search.brave.com/documentation/resources/terms-of-service
https://api-dashboard.search.brave.com/documentation/resources/help-feedback
```

### Tavily

```text
https://docs.tavily.com/documentation/api-credits
https://www.tavily.com/pricing
https://docs.tavily.com/documentation/quickstart
https://docs.tavily.com/documentation/rate-limits
https://docs.tavily.com/documentation/api-reference/endpoint/search
https://docs.tavily.com/faq/faq
https://docs.tavily.com/documentation/search-crawler
https://www.tavily.com/terms
```

### SearXNG

```text
https://docs.searxng.org/own-instance.html
https://docs.searxng.org/dev/search_api.html
https://docs.searxng.org/dev/result_types/main/mainresult.html
https://docs.searxng.org/admin/installation-docker.html
https://docs.searxng.org/admin/searx.limiter.html
https://docs.searxng.org/admin/settings/settings_search.html
https://docs.searxng.org/src/searx.exceptions.html
https://github.com/searxng/searxng
https://github.com/searxng/searxng/blob/master/CHANGELOG.rst
```

### Firecrawl newcomer check

```text
https://www.firecrawl.dev/pricing
https://docs.firecrawl.dev/api-reference/endpoint/search
https://docs.firecrawl.dev/api-reference/errors
https://www.firecrawl.dev/terms-of-service
```

## Open questions and limitations

A few items were **not** cleanly documented in current primary sources. Exa’s public docs do not clearly state whether a **credit card is required** for the free tier; I therefore did **not** assume one is required. Brave documents 429 handling through `X-RateLimit-*` headers, but I did not find a public statement that it sends a standard `Retry-After` header. Tavily documents `432` and `433` status codes on the search reference page, but the public page fragment available through docs search did not explain those two codes in detail. Firecrawl looks promising as an AI-native newcomer, but its public docs do not document index provenance with the same clarity as Exa or Brave, so I did not treat it as a stronger default candidate than the listed four. citeturn38search1turn20search0turn40view0turn10view0turn34view0turn32view1