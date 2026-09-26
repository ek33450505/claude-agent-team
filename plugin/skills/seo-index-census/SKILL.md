---
name: seo-index-census
description: Index-coverage census discipline for sites with many programmatic routes — when to run a census, how to read discovered-not-indexed vs crawled-not-indexed, GSC URL Inspection quota arithmetic, stratified sampling, drift baselines, and the pre-registered soak window. Load when investigating unindexed pages, crawl budget, sitemap segmentation, or programmatic-page scale risk.
user-invocable: false
allowed-tools: []
---

# Index-Coverage Census

## When to run a census

- **Trigger:** a site with many programmatic routes reports "a lot of unindexed pages"; after a sitemap segmentation; before and after a structural change; to refresh a stale baseline.
- **Not a per-deploy check** — the quota (below) makes that impossible, and index state moves over weeks, not deploys.
- A census answers "what state is every route in, and which route families differ". It does not answer "is the content good".

## The only instruments that report real index state

- `mcp__gsc__inspect_url_enhanced` (single URL) and `mcp__gsc__batch_url_inspection` (batch) are the ONLY calls that report per-URL index state.
- `get_sitemap_details` → `indexed` is ALWAYS `0`: the field is deprecated and carries no signal. Independently confirmed by a third-party tool that strips it before reporting.
- `get_sitemaps` → `indexed_urls` is the **submitted** count, not the indexed count. Reading it as coverage is a silent error.
- Google Search Console reports coverage **per sitemap**. One flat sitemap therefore makes "which route family is unindexed?" unanswerable from GSC at all — segmenting the sitemap by route family is diagnostic capability, not cosmetics.
- Record per URL at minimum: `coverageState`, `robotsTxtState`, `indexingState`, `lastCrawlTime`, `pageFetchState`.

## Reading the two failure states — they have different causes

| state | cause | levers |
|---|---|---|
| `Discovered – currently not indexed` (esp. last crawl = `Never`) | Google knows the URL — it is in the sitemap — but has never spent crawl budget on it. Crawl-demand / authority / internal-linking signal. | Internal links from strongly-linked pages, sitemap segmentation, external citations, reducing competing URLs. **Content depth does nothing for this state.** |
| `Crawled – currently not indexed` | Google fetched the page and judged it not worth indexing. Content-quality verdict. | Depth, uniqueness, consolidation. |

- Collapsing these two into "unindexed pages" is the standard misdiagnosis and it aims the fix at the wrong lever.
- **Measured instance** (Compute Atlas, 2026-09-15, stratified sample, per-stratum rate): of a 20-page established-facility control, 14 indexed (70%) and 6 (30%) were `Discovered – currently not indexed, last crawled Never`. **Zero** pages in any stratum returned `Crawled – currently not indexed`. The site's problem was crawl budget; the plan of record at the time had named content depth as the lever.
- Corollary: a hub page that has never been crawled cannot pass link equity to its children. Check the index state of the hub before theorising about its children.

## Quota arithmetic

- URL Inspection quota, verbatim from Google: **2,000 QPD and 600 QPM per property.**
- A sweep of N routes fits in one day only while N ≤ 2,000. Above that: split across days, or sample.
- 600 QPM is a 10 req/s ceiling; pace requests (prior art paces at 1.0 s between requests for safety, well under the cap).
- A census that spans days is not a snapshot. Stamp each record with its own fetch time, not just a single `takenAt` for the run, and say the span out loud when reporting.

## If you sample, stratify

- An unstratified sample of a population dominated by one family measures that family, not the site.
- **Stratify to measure a family; weight to project a site-wide number.** Check whether the population is concentrated before trusting an evenly-drawn rate.
- Never report a per-stratum rate as a site rate. Label every figure with the population it was drawn from.

## Soak windows

- GSC data lags **2–3 days**; index state moves over weeks.
- Any before/after needs a **≥14-day soak**, and the window must be **pre-registered before the change ships** — otherwise the comparison is post-hoc.
- Name the confounds in the same breath: any concurrent internal-linking or content change inside the window gives the movement more than one candidate cause. Say so when reporting rather than attributing it to the change you care about.

## What a passing census looks like

- A passing census is **"every route has a recorded state"** — not "most routes are indexed".
- State that criterion before you run it, while coverage is still broken. A census proves the measurement ran; it is never evidence that coverage is good.
- Reconcile the census's total URL count against the sitemap's URL count. A drift between them means the census and the sitemap are deriving routes from different sources — fix that first, they must share one source.

## Baseline and drift — "always was" vs "got worse"

- A one-off look cannot distinguish a family that just regressed from one that was never crawled. Only a time series can.
- Pattern: freeze a **baseline** census → **compare** a later census against it → keep an **append-only history** → report per-family movement: newly indexed, newly dropped, still discovered-never-crawled.
- Prior art for this pattern: `claude-seo` (MIT) `scripts/drift_baseline.py`, `drift_compare.py`, `drift_history.py`, `drift_report.py`. Pattern only — nothing is installed or copied.

## Programmatic pages at scale

Rubric ported from `claude-seo/skills/seo-sitemap/SKILL.md` (MIT, AgriciDaniel):

- **Safe at scale:** integration pages with real setup docs; template/tool pages with downloadable content; glossary pages with 200+ word definitions; product pages with unique specs and reviews; user-profile pages carrying user-generated content.
- **Penalty risk at scale:** location pages with only the city name swapped; "Best [tool] for [industry]" without industry-specific value; "[Competitor] alternative" without real comparison data; AI-generated pages without human review and unique value.

CAST-specific extension (this is ours, not claude-seo's):

- Count hub/index routes against the content they index. When hubs approach parity with the pages they exist to index, they compete for the same crawl budget.
- A hub with one or two children is a **consolidation** candidate, not an indexing candidate.
- Decide per family — keep, `noindex`, or consolidate — and only on census data, never on intuition.
- A retired hub slug can be **resurrected** by new data. Any redirect introduced by a triage wave must be re-checked against the live slug set on every subsequent wave.

## The Google Indexing API is not an option here

- It is restricted to `JobPosting` and `BroadcastEvent`-in-`VideoObject`. A site emitting `Place`, `Dataset`, or ordinary content pages is **not eligible**.
- Submitting ordinary URLs risks revocation of API access, and `URL_UPDATED` is not an indexing guarantee in any case.
- Recorded here so it is not re-proposed. It buys nothing and can cost the access.

## IndexNow is a different search engine

- IndexNow serves Bing and Yandex. It does **not** submit to Google.
- It therefore cannot fix a Google crawl-budget problem, whatever its README implies.

## Instrument traps (GSC MCP)

- **Domain properties need the `sc-domain:` form.** For a DNS-verified property, `site_url` must be `sc-domain:<domain>`. Passing `https://www.<domain>/` returns **403**, which reads exactly like a credential failure and sends you debugging the wrong thing.
- **`sort_by` / `sort_direction` are silently ignored.** Rows always come back clicks-descending, and the response echoes `"filters_applied": []`. You never get "top pages by impressions"; the zero-click tail arrives in alphabetical order, where punctuation- and digit-prefixed queries pile up at the top and look like a bot-traffic pattern that is not there.
- **A `page` filter combined with the `device` dimension silently loses data** — a filtered slice returned 0 clicks against a known-true three-figure count. The verified-good aggregate path is: filter by page, group by **`date`**, and sum the ≤31 rows by hand.
- General rule: reconcile every filtered slice against an unfiltered total before believing it. These failures are silent, well-formed, and plausible.
- **Sitemap submission is a human step.** `submit_sitemap` mutates by default, is not covered by the server's destructive-op gate, and is denied at the client layer. Ask the operator to resubmit each sitemap in the GSC UI; do not attempt it from an agent.

## Related

- `seo-checklist` — metadata, structured data, technical SEO, Core Web Vitals, GEO. This skill does not repeat any of it; it covers only index coverage and crawl budget. `seo-checklist` owns *is the page well-formed*; this skill owns *is the page in Google's index and why not*.

## Prior art

- `AgriciDaniel/claude-seo` (MIT). Borrowed as ideas and rubric text: the "Safe Programmatic Pages / Penalty Risk" lists (reproduced above), the baseline→compare→history drift pattern, and the batch-inspection pacing discipline.
- Nothing from it is installed, vendored, or executed. Its install safety, data egress, API-key handling and maintenance health have **not** been audited — do not let this attribution drift into a recommendation to install it.
