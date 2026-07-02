# Default Web Search Backend for Swift-Claw

## Executive Summary

- **Default Choice**: Exa is the best default because its official pricing page gives **20,000 free requests per month**, its rate-limit page lists **10 QPS** for `/search`, and its docs position the product as web search for agents -> use Exa as the default `SearchProviding` backend for 50-200 queries/day [executive_summary[0]] [10], [executive_summary[1]] [53], [executive_summary[2]] [8].
- **Cost Coverage**: 50-200 queries/day is about **1,500-6,000 queries/month**; Exa's **20,000/month free tier** covers the full range, while Brave and Tavily each publish only about **1,000/month** of free search-equivalent quota -> choose Exa if the default should stay free at the high end [executive_summary[0]] [10], [executive_summary[3]] [3], [executive_summary[4]] [40].
- **Wire Contract Trade-Off**: Brave is the cleanest thin wrapper because it is one `GET` with `X-Subscription-Token` and `web.results[].description`; Exa is a `POST` and needs `results[].highlights[0]` as the snippet -> accept Exa's slightly thicker adapter because it wins on free coverage and agent-oriented product fit [executive_summary[5]] [58], [executive_summary[6]] [42], [executive_summary[7]] [56].
- **ToS Cleanliness**: Tavily is the clearest on agent use because its terms define Customer Applications to include AI Tools and LLMs and mention Agent Keys for automated interaction; Exa and Linkup also market and document agent use, while Brave is usable only with strict no-cache and no model-training/evaluation safeguards -> keep Tavily as the best legal-clean fallback if budget is acceptable [executive_summary[8]] [38], [executive_summary[2]] [8], [executive_summary[9]] [69], [executive_summary[10]] [2].
- **Brave Strength And Limitation**: Brave has the best independent web-index story and simple GET contract, but its **$5/month free credit** at **$5 per 1,000 requests** only covers about **1,000 queries/month** -> make Brave an optional backend for users who prefer the simplest API and accept small monthly spend [executive_summary[3]] [3], [executive_summary[5]] [58].
- **SearXNG Risk**: SearXNG has zero direct API cost and a documented JSON API, but official docs say it aggregates results from up to **280 search services** and the limiter exists because SearXNG passes through bot requests and can be classified as a bot -> do not make it the default unless the owner wants operational ownership [executive_summary[11]] [49], [executive_summary[12]] [29], [executive_summary[13]] [31].
- **Newcomer Watch**: Linkup is the strongest newcomer found because its docs are explicitly for AI workflows, it offers a search route returning `sources[].url` and `sources[].snippet`, and its pricing page says users can run **4,000 queries for free** -> treat Linkup as a promising experimental backend, not the default, because public rate-limit and ToS detail was thinner than Exa/Tavily [executive_summary[14]] [46], [executive_summary[15]] [47], [executive_summary[9]] [69].
- **Firecrawl Screen-Out**: Firecrawl is useful for search plus scraping, but its free tier is **1,000 credits/month** and search costs **2 credits per 10 results**, so it does not cover 50-200 daily searches as cheaply as Exa -> do not include it as the default search provider [executive_summary[16]] [21], [executive_summary[17]] [27].

## Recommendation

Use **Exa Search API** as the default `SearchProviding` backend.

The decisive reason is not that Exa has the prettiest wire contract. It does not. Brave is closer to the ideal thin wrapper because it is a single authenticated `GET` and returns `web.results[].title`, `web.results[].url`, and `web.results[].description` directly. The reason Exa should be the default is that it is the best combined fit for this specific swift-claw profile: a single-owner, non-commercial, LLM-driven daily driver at 50-200 queries/day.

Exa is the only hosted candidate found with all of these at once: agent-oriented official docs, an independent AI-oriented search product, a documented **20,000 requests/month free tier**, and a documented **10 QPS** `/search` rate limit [recommendation[0]] [10], [recommendation[1]] [53], [recommendation[2]] [8]. For the high-end expected load of about **6,000 queries/month**, that leaves large free-tier headroom. The implementation cost is manageable: one `POST` request with `x-api-key`, `query`, `numResults`, and `contents.highlights`, then map `results[].title`, `results[].url`, and the first item of `results[].highlights` to swift-claw's `{title, url, snippet}` contract [recommendation[3]] [56].

The main caveats are privacy and simplicity. Exa's terms govern the API and restrict resale and competitive-product use, and the terms grant Exa rights to host, cache, and use user input/output to provide or improve services [recommendation[4]] [34]. The endpoint is also `POST`, not the ideal `GET`. If the owner strongly prioritizes a direct, classic search API shape over free-tier coverage, Brave is the best alternate default. If the owner prioritizes the cleanest explicit AI-agent legal language and is willing to pay after 1,000 monthly credits, Tavily is the best legal-clean alternate.

## Verification Matrix

| Candidate | 1. Pricing, Free Tier, Rate Limits | 2. ToS Position On Automated And LLM-Agent Use | 3. Wire Contract | 4. Key Provisioning | 5. Index Quality And Independence | 6. Operational Burden And Caveats |
|---|---|---|---|---|---|---|
| **Exa Search API** | Free tier: **20,000 requests/month**. Search cost above free: **$7 per 1,000 requests** for base search up to 10 results; extra results cost **$1 per 1,000 requests**; deep search is **$12-$15 per 1,000**. Rate limit: **10 QPS** for `/search`; monthly free quota is 20,000. The pricing page describes the free quota as monthly, not as a limited trial [verification_matrix[0]] [10], [verification_matrix[1]] [53]. | Official docs and pricing position Exa for web search, crawling, and research agents. Terms cover the API, restrict resale/sublicensing and competitive-product use, and grant Exa license rights to host/cache/use user input and output. This is acceptable for a personal assistant if the owner accepts Exa as a trust dependency and does not use results to build a competing product [verification_matrix[2]] [8], [verification_matrix[3]] [34]. | `POST https://api.exa.ai/search`. Auth: `x-api-key: <key>` or `Authorization: Bearer <key>`. Params: `query`, `numResults`, `type`, `category`, `userLocation`, `moderation`, and `contents` options such as `highlights` or `text`. Paths: `results[].title`, `results[].url`, and, if highlights are requested, `results[].highlights[]` for snippet text. Errors include **400**, **401**, **402**, **429**, and **500**; docs recommend exponential backoff on **429** and do not document `Retry-After` as the main contract [verification_matrix[4]] [56], [verification_matrix[5]] [36]. | API keys are created in the Exa dashboard. Official pages reviewed did not state whether a credit card is required for the free tier, so do not document "no card" unless confirmed during signup [verification_matrix[2]] [8]. | Exa describes itself as a custom search engine built for AIs and an AI-oriented search API. It is not a Google/Bing SERP wrapper in the official docs reviewed. Freshness can be controlled through content options such as `maxAgeHours`, including live crawl behavior in the coding-agent reference [verification_matrix[2]] [8]. | Hosted API, low operational burden. Main adapter caveat: no plain `snippet` field, so request `contents.highlights` and map `results[].highlights[0]` to `snippet`. Main policy caveat: Exa sees queries and outputs under its terms [verification_matrix[3]] [34]. |
| **Brave Search API** | Free credits: **$5 every month**. Web Search price: **$5 per 1,000 requests**, so the free credit covers about **1,000 web-search requests/month**. Search capacity: **50 requests/second**. Free credits are described as monthly and automatic, not as a time-limited trial [verification_matrix[6]] [3]. | Official terms prohibit caching, storing, or creating databases of search results except transient storage required for operation. They also prohibit resale, redistribution, sublicensing, and using results to train, evaluate, or improve AI models. This can be compatible with ephemeral RAG-style inference, but swift-claw must not cache results beyond operational need and must not use them for model training/evaluation [verification_matrix[7]] [2]. | `GET https://api.search.brave.com/res/v1/web/search`. Auth: `X-Subscription-Token: <key>`. Params include `q`, `count` with max **20**, `country`, `search_lang`, `ui_lang`, `safesearch`, and `freshness`. Paths: `web.results[].title`, `web.results[].url`, `web.results[].description`. Rate-limit headers include `X-RateLimit-Limit`, `X-RateLimit-Remaining`, and `X-RateLimit-Reset`; **429** indicates rate limit exhaustion. No `Retry-After` dependency is needed if the client uses `X-RateLimit-Reset` [verification_matrix[8]] [58], [verification_matrix[9]] [42], [verification_matrix[10]] [54]. | Subscribe to a plan, then create and copy the API key from the dashboard. Official pages reviewed did not state whether a credit card is required for the free monthly credits [verification_matrix[9]] [42]. | Strongest classic search-index story. Brave documents Web Search as access to a large index of web pages, and Brave's Search API documentation positions the service as an independent web-search API [verification_matrix[8]] [58], [verification_matrix[11]] [5]. | Hosted and simple. Main caveat is legal/behavioral: do not cache/store search results except transiently, do not build a result database, and do not train/evaluate/improve AI models with results [verification_matrix[7]] [2]. |
| **Tavily** | Free tier: **1,000 API credits/month**, no credit card required. Basic, fast, and ultra-fast search cost **1 credit**; advanced costs **2 credits**. Pay-as-you-go is **$0.008 per credit**, so basic search is about **$8 per 1,000** and advanced is about **$16 per 1,000**. Rate limits: **100 RPM** development and **1,000 RPM** production for general search. Free credits are described as monthly, not a time-limited trial [verification_matrix[12]] [40], [verification_matrix[13]] [33], [verification_matrix[14]] [39]. | Clearest ToS language for agents. Tavily terms describe services as usable through APIs or Agent Keys, define Customer Applications to include AI Tools and LLMs, and allow automated interaction through Agent Keys. Restrictions include no resale/distribution of the service, no competing model/product development with output, and no high-risk automated decisions without oversight [verification_matrix[15]] [38]. | Base URL: `https://api.tavily.com`; endpoint: `POST /search`. Auth: `Authorization: Bearer tvly-...`. Params include `query`, `search_depth`, `topic`, `max_results`, `country`, `include_domains`, `exclude_domains`, `time_range`, `start_date`, `end_date`, and `safe_search` where documented as Enterprise-only and not supported for fast/ultra-fast. No general language param was found. Paths: `results[].title`, `results[].url`, `results[].content`. Errors include **400**, **401**, **429**, **432**, **433**, and **500**. **429** responses include a `retry-after` header [verification_matrix[16]] [20], [verification_matrix[17]] [18], [verification_matrix[14]] [39]. | Get a free API key at the Tavily app. Official pricing and credit docs explicitly say **no credit card required** for free credits [verification_matrix[12]] [40], [verification_matrix[13]] [33]. | Strong agent/RAG ergonomics and freshness controls, including topic `news` and date filters. Official pages reviewed did not disclose a fully independent crawl/index equivalent to Brave or Exa, so index independence remains less clear [verification_matrix[17]] [18]. | Hosted and low burden. Main caveat is cost: the free tier does not cover 50-200/day. At 6,000 basic searches/month, about 5,000 paid credits remain after the free tier, or about **$40/month** at $0.008/credit [verification_matrix[12]] [40]. |
| **SearXNG, self-hosted** | No vendor API fee and no vendor monthly quota. Local rate limits are whatever the owner configures, but effective limits depend on upstream engines. There is no durable, official monthly quota because SearXNG is a metasearch engine, not an index provider [verification_matrix[18]] [49], [verification_matrix[19]] [31]. | SearXNG itself is open-source software, but it sends queries to upstream search services. Official docs do not grant permission from Google, Bing, DuckDuckGo, or other engines. The limiter docs state SearXNG passes through bot requests and is thus classified as a bot, which is the key ToS/traffic-tolerance risk [verification_matrix[19]] [31]. | `GET` or `POST` to `/search` or `/`, with `format=json`. Params include `q`, `categories`, `engines`, `language`, `pageno`, `time_range`, and `safesearch`. JSON must be enabled in settings formats. Paths: `results[].title`, `results[].url`, `results[].content`. No keyed auth by default; any auth would be reverse-proxy/local network design [verification_matrix[20]] [29], [verification_matrix[21]] [11]. | No API key. Owner must deploy and protect the instance. Docker/container docs assume familiarity with container architecture and require configuration of the service and settings [verification_matrix[22]] [50]. | Not an independent index. SearXNG aggregates results from up to **280 search services**. Quality and freshness vary by enabled engine, engine HTML/API changes, throttling, and whether public engines block the instance [verification_matrix[18]] [49]. | Highest operational burden. The owner must run the container, configure `settings.yml`, enable JSON, manage limiter behavior, choose engines, monitor breakage, and avoid running an open proxy-like public instance. Good for privacy/control experiments, not as the default low-maintenance backend [verification_matrix[22]] [50], [verification_matrix[19]] [31]. |
| **Linkup, strong newcomer** | Public pricing says users can run **4,000 queries for free**. Docs say eligible accounts are topped back to **$20 each month**; search costs range from **$0.005 to $0.055 per request** depending on depth/output, so fast/standard search is about **$5 per 1,000**. Public pages reviewed did not expose a precise QPS limit [verification_matrix[23]] [46], [verification_matrix[24]] [47]. | Linkup docs explicitly say the API can be used in AI workflows and can retrieve context to ground an LLM answer, described as RAG over the live internet. A full public terms page specific to docs.linkup.so was not found in the official pages reviewed, so ToS confidence is lower than Tavily and Exa [verification_matrix[25]] [69]. | Search route: `https://api.linkup.so/v1/search`. Auth: `Authorization: Bearer <key>`. Docs also mention x402 pay-per-request. Params include `q`, `depth`, `outputType`, `maxResults`, `includeDomains`, `excludeDomains`, `fromDate`, and `toDate`. For source/snippet output, paths include `sources[].url` and `sources[].snippet`; docs also show source metadata such as name/favicon. Public error/rate docs were thinner than Exa/Tavily [verification_matrix[26]] [68], [verification_matrix[25]] [69], [verification_matrix[27]] [25]. | Create a Linkup account for free to get an API key. Official docs reviewed did not state a credit-card requirement. x402 can be used without an account for per-request USDC payment [verification_matrix[26]] [68]. | Linkup describes AI-oriented search depths and live-internet RAG. Docs reviewed indicate proprietary or optimized retrieval for fast mode and more agentic live retrieval for deeper modes, but the independence story is less established than Brave/Exa [verification_matrix[27]] [25]. | Promising but not default yet. It is simple and agent-oriented, but public ToS/rate-limit detail is less complete, and free coverage at $0.005/request is around **4,000 fast/standard queries/month**, below the 200/day high end [verification_matrix[24]] [47]. |

The table points to a narrow decision: **Exa wins the default slot**, Brave wins the "simplest GET" slot, Tavily wins the "clearest LLM-agent terms" slot, SearXNG wins the "no vendor dependency" slot, and Linkup is the newcomer to watch.

## Recommended API Wire Contract

Use Exa's `/search` endpoint and request highlights so the adapter has a snippet-like field. Exa's docs list `POST https://api.exa.ai/search`, `x-api-key` auth, `query`, `numResults`, `moderation`, and `contents.highlights`; response results expose `title`, `url`, `highlights`, and optional `text` [recommended_api_wire_contract[0]] [56], [recommended_api_wire_contract[1]] [8].

### Complete Example Request

```bash
curl -X POST 'https://api.exa.ai/search' \
  -H 'x-api-key: ${EXA_API_KEY}' \
  -H 'Content-Type: application/json' \
  -d '{
    "query": "Swift daemon Telegram bot private AI assistant web search API",
    "numResults": 10,
    "type": "auto",
    "userLocation": "US",
    "moderation": true,
    "contents": {
      "highlights": true
    }
  }'
```

### Trimmed Example Response And Mapping

```json
{
  "requestId": "req_example",
  "results": [
    {
      "id": "https://example.com/swift-daemon-guide",
      "title": "Building Long-Running Swift Daemons",
      "url": "https://example.com/swift-daemon-guide",
      "highlights": [
        "This guide explains launchd configuration, process supervision, and background service design for Swift applications on macOS."
      ]
    },
    {
      "id": "https://example.org/telegram-bot-api",
      "title": "Telegram Bot API Overview",
      "url": "https://example.org/telegram-bot-api",
      "highlights": [
        "Telegram bots receive updates through HTTPS endpoints or polling and can be controlled with private bot tokens."
      ]
    }
  ]
}
```

`SearchProviding` mapping:

| swift-claw field | Exa JSON path | Notes |
|---|---|---|
| `title` | `results[i].title` | Direct string path [recommended_api_wire_contract[0]] [56]. |
| `url` | `results[i].url` | Direct string path [recommended_api_wire_contract[0]] [56]. |
| `snippet` | `results[i].highlights[0]` | Request `contents.highlights`; if missing or empty, return an empty string or fall back to `results[i].text` only if `contents.text` was requested [recommended_api_wire_contract[1]] [8]. |

Implementation recommendation: keep the Exa key in the encrypted secret store, pin `https://api.exa.ai/search` as the configured endpoint, set a local timeout and retry budget, and use exponential backoff for **429** because Exa's error docs recommend backoff rather than relying on a documented `Retry-After` header [recommended_api_wire_contract[2]] [36].

## Candidate Case Studies

### Exa As The Default Daily-Driver Backend

The swift-claw decision is a resource-fit problem. At 50-200 queries/day, the owner needs about 1,500-6,000 searches/month. Exa's official free tier is **20,000 requests/month**, which covers that range without requiring SearXNG-style operations or Tavily/Brave overage spending [candidate_case_studies[0]] [10]. The mechanism is simple: a generous monthly free quota plus a hosted API removes both cost and maintenance pressure.

The trade-off is adapter complexity. Exa does not return a field literally named `snippet`; the adapter should request highlights and map `results[].highlights[0]` to `snippet` [candidate_case_studies[1]] [56]. That is a small one-time complexity in Swift, and it is less risky than making SearXNG the default or forcing the owner into paid overage when usage reaches the high end.

### Brave As The Simplicity Fallback

Brave is what the protocol designer would choose if wire shape were the top criterion. It is a keyed `GET` to `https://api.search.brave.com/res/v1/web/search`, authenticated by `X-Subscription-Token`, and its organic result paths directly map to the target shape: `web.results[].title`, `web.results[].url`, and `web.results[].description` [candidate_case_studies[2]] [58], [candidate_case_studies[3]] [42].

The problem is that the product/legal envelope is tighter. Brave's free monthly credit covers about **1,000 web searches/month**, below swift-claw's high-end use case, and its terms prohibit caching/storing results except transiently and prohibit training, evaluating, or improving AI models with results [candidate_case_studies[4]] [3], [candidate_case_studies[5]] [2]. If implemented as an optional backend, swift-claw should treat Brave results as ephemeral display/inference context only.

### Tavily As The Legal-Clean Agent Fallback

Tavily has the clearest legal posture for LLM agents. Its terms explicitly discuss Customer Applications including AI Tools and LLMs, and Agent Keys for automated interaction between agents and the services [candidate_case_studies[6]] [38]. The mechanism is contractual clarity: Tavily is built around the exact use pattern swift-claw has.

The limitation is cost coverage. The free tier is **1,000 credits/month**, and basic searches cost **1 credit** while advanced searches cost **2 credits**; pay-as-you-go is **$0.008 per credit** [candidate_case_studies[7]] [40]. That means Tavily is excellent if the owner wants explicit agent terms and accepts overage, but it is not the best default for an indefinitely free 50-200/day daily driver.

### SearXNG As The Control-First Failure Mode

SearXNG is attractive because it is self-hosted and has a documented `/search?format=json` API with result paths like `results[].title`, `results[].url`, and `results[].content` [candidate_case_studies[8]] [29]. For a single owner, that looks like the most private and cheapest route.

The hidden cost is reliability. SearXNG is a metasearch engine that aggregates results from up to **280 search services**, and its limiter exists because SearXNG passes bot-like traffic through to engines and can be classified as a bot itself [candidate_case_studies[9]] [49], [candidate_case_studies[10]] [31]. That means the owner inherits container maintenance, engine configuration, JSON enablement, rate-limit tuning, and upstream breakage. It is a good power-user backend, not the default for low operational burden.

## Synthesis

Across the candidates, the core tension is **wire simplicity versus operational and economic fit**. Brave has the best one-call REST shape and an independent index, but its free tier is smaller and its terms require stricter handling of result storage and model use. Exa has a less direct snippet mapping, but it is the only hosted API that clearly covers the full 50-200/day range for free while remaining agent-oriented and low-maintenance.

The second tension is **legal clarity versus cost**. Tavily is the strongest source for explicit LLM-agent permission, including AI Tools, LLMs, and Agent Keys in its terms [synthesis[0]] [38]. But Tavily's free tier is only 1,000 credits/month, so the mechanism that gives legal clarity also comes with a recurring usage cost at daily-driver scale [synthesis[1]] [40]. Exa's terms are less tailored in wording, but the product docs and pricing are explicitly agent-oriented and the free quota is large enough for the use case [synthesis[2]] [10], [synthesis[3]] [8].

The third tension is **vendor trust versus self-hosting risk**. SearXNG removes a direct API vendor and can be pinned to a local owner-controlled endpoint, but it replaces vendor trust with upstream-engine fragility and operational work. Official SearXNG docs make that trade-off visible: it aggregates many third-party engines, must be configured, and uses a limiter because bot-like traffic can get the instance classified as a bot [synthesis[4]] [49], [synthesis[5]] [31]. For swift-claw, that violates the low-burden criterion unless hosted APIs become legally or economically unacceptable.

Therefore the best architecture is: **default Exa**, keep **Brave** as a simple independent-index fallback, keep **Tavily** as the legal-clean paid fallback, and support **SearXNG** only as an owner-opt-in advanced backend. Linkup should be watched because it combines AI-agent positioning, snippets, and free monthly credits, but it should not displace Exa until its public ToS/rate-limit story is as complete as the incumbents.

## References

1. *Brave Search API | Brave*. https://api-dashboard.search.brave.com/
2. *SEARCH API TERMS OF USE - api-dashboard.search.brave.com*. https://api-dashboard.search.brave.com/terms-of-service
3. *Pricing - Brave Search API*. https://api-dashboard.search.brave.com/documentation/pricing
4. *Terms of service - Brave Search API*. https://api-dashboard.search.brave.com/documentation/resources/terms-of-service
5. *Documentation - Brave Search API*. https://api-dashboard.search.brave.com/documentation
6. *Exa | Web Search API, AI Search Engine, & Website Crawler*. http://exa.ai/
7. *Exa Search API - Exa*. https://docs.exa.ai/
8. *Search API Reference - exa.ai*. https://exa.ai/docs/reference/search-api-guide-for-coding-agents
9. *Exa AI Search - LiteLLM*. https://docs.litellm.ai/docs/search/exa_ai
10. *API Pricing - Exa*. https://exa.ai/pricing
11. *settings.yml - SearXNG Documentation (2026.6.5+37187dc2d)*. https://docs.searxng.org/admin/settings/settings.html
12. *searxng/settings.yml · gitdeem/searxng at main - Hugging Face*. https://huggingface.co/spaces/gitdeem/searxng/blob/main/searxng/settings.yml
13. *settings.yml — SearXNG Documentation (2023.12.11+8a4104b99)*. https://dokk.org/documentation/searxng/2023-12-11-8a4104b9/admin/settings/settings
14. *settings.yml — Searx Documentation (Searx-1.1.0.tex)*. https://searx.github.io/searx/admin/settings.html
15. *SearXNG 搜索 - OpenClaw*. https://docs.openclaw.ai/zh-CN/tools/searxng-search
16. *Tavily*. http://tavily.com/
17. *Welcome - Tavily Docs*. https://docs.tavily.com/
18. *Tavily Search - Tavily Docs*. https://docs.tavily.com/documentation/api-reference/endpoint/search
19. *SDK Reference - Tavily Docs*. https://docs.tavily.com/sdk/python/reference
20. *Introduction - Tavily Docs*. https://docs.tavily.com/documentation/api-reference/introduction
21. *Pricing | Firecrawl*. https://www.firecrawl.dev/pricing
22. *Firecrawl - The context API to search, scrape, and interact with ...*. https://www.firecrawl.dev/
23. *Linkup Pricing 2026 - costbench.com*. https://costbench.com/software/ai-search-apis/linkup
24. *Top 10 Web Scraping APIs for AI in 2026*. http://context.dev/blog/top-10-web-scraping-apis-for-ai
25. *Search overview - Linkup API Documentation*. https://docs.linkup.so/pages/documentation/endpoints/search/overview
26. *Terms of Service | Firecrawl*. https://www.firecrawl.dev/terms-of-service
27. *Search*. https://docs.firecrawl.dev/api-reference/endpoint/search
28. *Introduction*. https://docs.firecrawl.dev/introduction
29. *Search API - SearXNG Documentation (2026.6.30+d115c61a7)*. https://docs.searxng.org/dev/search_api.html
30. *Installation - SearXNG Documentation (2026.6.30+d115c61a7)*. https://docs.searxng.org/admin/installation.html
31. *Limiter - SearXNG Documentation (2026.6.30+d115c61a7)*. https://docs.searxng.org/admin/searx.limiter.html
32. *Page not found — SearXNG Documentation (2026.4.29+cba0cffa8)*. https://docs.searxng.org/admin/engines/settings.html
33. *Tavily*. https://www.tavily.com/pricing
34. *Fetched web page*. https://exa.ai/terms
35. *Search*. https://docs.exa.ai/reference/search
36. *Error Codes - Exa*. https://exa.ai/docs/reference/error-codes
37. *Exa Search API*. https://exa.ai/docs/reference/search-api-guide
38. *Tavily – Platform Terms of Service*. https://www.tavily.com/terms
39. *Rate Limits*. https://docs.tavily.com/documentation/rate-limits
40. *Credits & Pricing*. https://docs.tavily.com/documentation/api-credits
41. *Pricing*. https://help.tavily.com/articles/8816424538-pricing
42. *Authentication - Brave Search API*. https://api-dashboard.search.brave.com/documentation/guides/authentication
43. *Brave Search API Free Tier, Signup Credits, and Limits ...*. https://yangmao.ai/en/providers/brave-search-api/free-tier
44. *Documentation - Brave Search API*. https://api-dashboard.search.brave.com/app/documentation/web-search/get-started
45. *Linkup - Linkup: the production-grade Web Search API for AI*. http://linkup.so/
46. *Linkup - Pricing*. https://www.linkup.so/pricing
47. *Pricing - Linkup API Documentation*. https://docs.linkup.so/pages/documentation/platform/pricing
48. *Pricing | LinkupAPI*. https://linkupapi.com/pricing
49. *SearXNG Documentation (2026.6.20+fd42d4fda)*. https://docs.searxng.org/
50. *Installation container - SearXNG Documentation (2026.6.24 ...*. https://docs.searxng.org/admin/installation-docker.html
51. *SearXNG Settings | searxng/searxng-docker | DeepWiki*. https://deepwiki.com/searxng/searxng-docker/3.2-searxng-settings
52. *How to run SearXNG with Docker | remarkablemark*. https://remarkablemark.org/blog/2026/05/10/how-to-run-searxng-with-docker
53. *Rate Limits - Exa*. https://exa.ai/docs/reference/rate-limits
54. *Brave Search - API*. https://api-dashboard.search.brave.com/documentation/guides/rate-limiting
55. *Search Best Practices*. http://exa.ai/docs/reference/search-best-practices
56. *Search - Exa*. https://exa.ai/docs/reference/search
57. *Exa | Web Search API, AI Search Engine, & Website Crawler*. https://exa.ai/
58. *Web search - Brave Search API*. https://api-dashboard.search.brave.com/documentation/services/web-search
59. *Brave Search - API*. https://api-dashboard.search.brave.com/app/documentation/suggest-search/query
60. *Brave Search - API*. https://api-dashboard.search.brave.com/app/documentation/suggest-search/responses
61. *Brave Search - API*. https://api-dashboard.search.brave.com/app/documentation/image-search/codes
62. *Firecrawl Pricing 2026: Free-$749/User Plans Compared*. https://costbench.com/software/web-scraping/firecrawl
63. *Firecrawl pricing in 2026: plans, real costs, and what to ...*. https://www.eesel.ai/blog/firecrawl-pricing
64. *Firecrawl Review 2026: 1,000 Free Credits, Worth $16/mo?*. https://use-apify.com/blog/firecrawl-review-2026
65. *searx.limiter - SearXNG Documentation (2026.6.8+f3fab143b)*. https://docs.searxng.org/_modules/searx/limiter.html
66. *Rotating proxies and ratelimit mitigation · searxng searxng ...*. https://github.com/searxng/searxng/discussions/2567
67. *Deploy SearXNG | Open Source Search API for AI Agents*. https://railway.com/deploy/searxng-search-api
68. *Authentication - Linkup API Documentation*. https://docs.linkup.so/pages/documentation/platform/authentication
69. *Quickstart - Linkup API Documentation*. https://docs.linkup.so/pages/documentation/get-started/quickstart
70. *Terms of Use | LinkUp*. https://www.linkup.com/terms-of-use
71. *Introduction - LinkUp API*. https://docs.linkupapi.com/api-reference/introduction
72. *Search*. https://docs.firecrawl.dev/features/search
