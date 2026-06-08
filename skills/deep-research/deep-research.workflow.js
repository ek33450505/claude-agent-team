export const meta = {
  name: 'deep-research',
  description: 'Deep research harness — fan-out web searches, fetch sources, adversarially verify claims, synthesize a cited report.',
  whenToUse: 'When the user wants a deep, multi-source, fact-checked research report on any topic. BEFORE invoking, check if the question is specific enough to research directly — if underspecified (e.g., "what car to buy" without budget/use-case/region), ask 2-3 clarifying questions to narrow scope. Then pass the refined question as args, weaving the answers in.',
  phases: [{"title":"Scope","detail":"Decompose question (from args) into 5 search angles"},{"title":"Search","detail":"5 parallel WebSearch agents, one per angle"},{"title":"Fetch","detail":"URL-dedup, fetch top 10 sources, extract falsifiable claims"},{"title":"Verify","detail":"3-vote adversarial verification per claim, in paced batches (need 2/3 refutes to kill)"},{"title":"Synthesize","detail":"Merge semantic dupes, rank by confidence, cite sources"}],
}

// deep-research: Scope → pipeline(Search → URL-dedup → Fetch+Extract) → 3-vote Verify → Synthesize
// Ported from bughunter architecture. WebSearch/WebFetch instead of git/grep.
// Question is passed via Workflow({name: 'deep-research', args: '<question>'}).
//
// ─── 2026-06-08 correctness fix (run wf_99d3590b-d52 post-mortem) ───────────────
// Two structural bugs were collapsing whole runs to zero findings:
//   (1) VERIFY bucketing false-negative — when the 3 verifier subagents failed to
//       emit StructuredOutput, the claim recorded "0-0 (3 abstain)" and was bucketed
//       as KILLED. Absence of a verdict was being treated as a refutation. A claim is
//       now killed ONLY by >= REFUTATIONS_REQUIRED *actual* refute votes; too-few valid
//       votes => "unverified" (a distinct third outcome), never refuted.
//   (2) The same "subagent completed without calling StructuredOutput" failure also hit
//       FETCH (and SCOPE/SEARCH/SYNTHESIZE): a single tooling hiccup dropped otherwise-good
//       sources to claimCount 0 / "unreliable" and could zero out the run.
// Root cause for BOTH: an agent that does heavy tool work (WebFetch/WebSearch) then ends
// in prose without the final StructuredOutput call. Prompt-hardening did NOT fix it
// (proven on a re-run — identical 100% failure). The structural fix is structuredWithFallback():
// when a schema'd call fails, re-run the work as a FREE-TEXT agent (no schema, no
// StructuredOutput pressure), then hand that prose to a STRUCTURE-ONLY agent whose sole job
// is to emit StructuredOutput (no web tools to distract it). Unverified claims and
// fetch-failed sources are SURFACED in the output, never silently dropped or mislabeled refuted.
// ────────────────────────────────────────────────────────────────────────────────
//
// ─── 2026-06-08 follow-up (live run wf_2b84c096 post-mortem) ─────────────────────
// The live re-run proved the VERIFY failures were SERVER-SIDE RATE LIMITING ("Server is temporarily
// limiting requests (not your usage limit) · Rate limited") — NOT the model forgetting StructuredOutput.
// Worse, the per-call free-text→structure fallback AMPLIFIED the load (75 verify votes → 225 agents,
// 0 recovered), prolonging the throttle. Fetch/search/scope (≤19 agents) never tripped the limiter.
// The thrown error is the generic "no StructuredOutput" (the rate-limit text lives inside the subagent
// transcript), so the cause can't be detected at the call site — the only lever is LOAD REDUCTION.
// Fix: VERIFY now runs in small SEQUENTIAL batches (VERIFY_BATCH claims each) with a DIRECT structured
// call and NO fallback amplification; each batch fully drains before the next, pacing the request rate
// to the fetch-phase profile that succeeds. A failed/limited vote → abstain → unverified (never
// refuted). structuredWithFallback() is kept only for the LOW-fan-out phases (scope/search/fetch/
// synthesize), where "agent forgot StructuredOutput" is plausible and amplification is bounded.
// ────────────────────────────────────────────────────────────────────────────────

const VOTES_PER_CLAIM = 3
const REFUTATIONS_REQUIRED = 2
const MAX_FETCH = 10            // dialed back 2026-06-08 (was 15) to lighten load on a busy service
const MAX_VERIFY_CLAIMS = 12    // dialed back 2026-06-08 (was 25): verify is the heaviest phase — 12×3 = 36 votes vs 75
const VERIFY_BATCH = 4         // claims per sequential verify batch (× VOTES_PER_CLAIM = peak concurrent votes); paces requests to dodge the server rate limiter

// ─── Schemas ───
const SCOPE_SCHEMA = {
  type: "object", required: ["question", "angles", "summary"],
  properties: {
    question: { type: "string" },
    summary: { type: "string" },
    angles: { type: "array", minItems: 3, maxItems: 6, items: {
      type: "object", required: ["label", "query"],
      properties: {
        label: { type: "string" },
        query: { type: "string" },
        rationale: { type: "string" },
      },
    }},
  },
}
const SEARCH_SCHEMA = {
  type: "object", required: ["results"],
  properties: {
    results: { type: "array", maxItems: 6, items: {
      type: "object", required: ["url", "title", "relevance"],
      properties: {
        url: { type: "string" },
        title: { type: "string" },
        snippet: { type: "string" },
        relevance: { enum: ["high", "medium", "low"] },
      },
    }},
  },
}
const EXTRACT_SCHEMA = {
  type: "object", required: ["claims", "sourceQuality"],
  properties: {
    sourceQuality: { enum: ["primary", "secondary", "blog", "forum", "unreliable"] },
    publishDate: { type: "string" },
    claims: { type: "array", maxItems: 5, items: {
      type: "object", required: ["claim", "quote", "importance"],
      properties: {
        claim: { type: "string" },
        quote: { type: "string" },
        importance: { enum: ["central", "supporting", "tangential"] },
      },
    }},
  },
}
const VERDICT_SCHEMA = {
  type: "object", required: ["refuted", "evidence", "confidence"],
  properties: {
    refuted: { type: "boolean" },
    evidence: { type: "string" },
    confidence: { enum: ["high", "medium", "low"] },
    counterSource: { type: "string" },
  },
}
const REPORT_SCHEMA = {
  type: "object", required: ["summary", "findings", "caveats"],
  properties: {
    summary: { type: "string" },
    findings: { type: "array", items: {
      type: "object", required: ["claim", "confidence", "sources", "evidence"],
      properties: {
        claim: { type: "string" },
        confidence: { enum: ["high", "medium", "low"] },
        sources: { type: "array", items: { type: "string" } },
        evidence: { type: "string" },
        vote: { type: "string" },
      },
    }},
    caveats: { type: "string" },
    openQuestions: { type: "array", items: { type: "string" } },
  },
}

// ─── Structured-output resilience ───────────────────────────────────────────────
// Observability counters (surfaced in stats + a final log) so a run shows how often the
// structural StructuredOutput failure was hit and how often the fallback recovered it.
let fallbackFired = 0
let fallbackRecovered = 0

const STRUCTURED_SUFFIX =
  "\n\n## REQUIRED — finish by calling the StructuredOutput tool with your result. " +
  "Ending in prose WITHOUT the StructuredOutput call discards your work. Do not narrate; render the structured result."

const PROSE_SUFFIX =
  "\n\n## Output mode: PROSE\n" +
  "Do the work, then state your COMPLETE result in plain prose — cover every field the task asked for, explicitly and unambiguously. " +
  "Do NOT call StructuredOutput or any structuring tool in this step; just write the answer out."

// structuredWithFallback: get a schema-valid object from an agent, resilient to the
// "subagent completed without calling StructuredOutput" structural failure.
//   1) Normal structured attempt.
//   2) On failure, re-run the SAME work as a free-text agent (no schema) so the model can
//      do its tool work and reason in prose without StructuredOutput pressure.
//   3) Hand that prose to a structure-ONLY agent (no web work) whose single job is to emit
//      the StructuredOutput call — the high-reliability path.
// Returns the validated object, or null if even the fallback can't produce structure
// (callers treat null as abstain/unreliable and SURFACE it — never as a refutation).
async function structuredWithFallback(workPrompt, schema, opts) {
  const label = (opts && opts.label) || "agent"
  const phase = opts && opts.phase
  const base = phase ? { label, phase } : { label }
  // 1) structured attempt
  try {
    const direct = await agent(workPrompt + STRUCTURED_SUFFIX, { ...base, schema })
    return direct  // null here = genuine user-skip; do NOT burn the fallback on it
  } catch (e) {
    // typically: agent({schema}): subagent completed without calling StructuredOutput
  }
  fallbackFired++
  log("⤷ structured call failed (" + label + ") — retrying via free-text → structure")
  // 2) free-text work pass (no schema)
  let raw
  try {
    raw = await agent(workPrompt + PROSE_SUFFIX, { ...base, label: label + "·prose" })
  } catch (e2) {
    return null
  }
  if (!raw || !String(raw).trim()) return null
  // 3) structure-only pass (no web work, sole job = emit StructuredOutput)
  try {
    const structured = await agent(
      "## Structuring pass — no research, no web tools\n\n" +
      "Convert the analysis below into the required structured result. Do NOT do any new research or call any tool except StructuredOutput. " +
      "Re-express only what is already written; if a required field is not explicit in the text, infer the most faithful value from what is written.\n\n" +
      "## Analysis to structure\n" + String(raw) +
      "\n\n## REQUIRED — your ONLY action is to call the StructuredOutput tool with the result. Do not narrate.",
      { ...base, label: label + "·structure", schema }
    )
    if (structured) fallbackRecovered++
    return structured
  } catch (e3) {
    return null
  }
}

// ─── Phase 0: Scope — decompose question into search angles ───
phase("Scope")
const QUESTION = (typeof args === "string" && args.trim()) || ""
if (!QUESTION) {
  return { error: "No research question provided. Pass it as args: Workflow({name: 'deep-research', args: '<question>'})." }
}
const scope = await structuredWithFallback(
  "Decompose this research question into complementary search angles.\n\n" +
  "## Question\n" + QUESTION + "\n\n" +
  "## Task\n" +
  "Generate 5 distinct web search queries that together cover the question from different angles. Pick angles that suit the question's domain. Examples:\n" +
  "- broad/primary  · academic/technical  · recent news  · contrarian/skeptical  · practitioner/implementation\n" +
  "- For medical: anatomy · common causes · serious differentials · authoritative refs · red flags\n" +
  "- For tech: state-of-art · benchmarks · limitations · industry adoption · cost/tradeoffs\n\n" +
  "Make queries specific enough to surface high-signal results. Avoid redundancy.\n" +
  "Return: the question (verbatim or lightly normalized), a 1-2 sentence decomposition strategy, and the angles.",
  SCOPE_SCHEMA,
  { label: "scope", phase: "Scope" }
)
if (!scope) {
  return { error: "Scope agent returned no result — cannot decompose the research question." }
}
log("Q: " + QUESTION.slice(0, 80) + (QUESTION.length > 80 ? "…" : ""))
log("Decomposed into " + scope.angles.length + " angles: " + scope.angles.map(a => a.label).join(", "))

// ─── Dedup state — accumulates across searchers as they complete ───
const normURL = u => {
  try {
    const p = new URL(u)
    return (p.hostname.replace(/^www\./, "") + p.pathname.replace(/\/$/, "")).toLowerCase()
  } catch { return u.toLowerCase() }
}
const seen = new Map()
const dupes = []
const budgetDropped = []
const relRank = { high: 0, medium: 1, low: 2 }
let fetchSlots = MAX_FETCH

// ─── Prompts ───
// NOTE: base prompts intentionally end at the task description — the StructuredOutput
// demand (or the PROSE override) is appended by structuredWithFallback per attempt.
const SEARCH_PROMPT = (angle) =>
  "## Web Searcher: " + angle.label + "\n\n" +
  "Research question: \"" + QUESTION + "\"\n\n" +
  "Your angle: **" + angle.label + "** — " + (angle.rationale || "") + "\n" +
  "Search query: `" + angle.query + "`\n\n" +
  "## Task\nUse WebSearch with the query above (or a refined version). Return the top 4-6 most relevant results.\n" +
  "Rank by relevance to the ORIGINAL question, not just the search query. Skip obvious SEO spam/content farms.\n" +
  "Include a short snippet capturing why each result is relevant."

const FETCH_PROMPT = (source, angle) =>
  "## Source Extractor\n\n" +
  "Research question: \"" + QUESTION + "\"\n\n" +
  "Fetch and extract key claims from this source:\n" +
  "**URL:** " + source.url + "\n**Title:** " + source.title + "\n**Found via:** " + angle + " search\n\n" +
  "## Task\n1. Use WebFetch to retrieve the page content. Make at most two attempts — if it errors, times out, or is paywalled, STOP retrying and move on.\n" +
  "2. Assess source quality: primary research/institution? secondary reporting? blog/opinion? forum? unreliable?\n" +
  "3. Extract 2-5 FALSIFIABLE claims that bear on the research question. Each claim must:\n" +
  "   - be a concrete, checkable statement (not vague generalities)\n" +
  "   - include a direct quote from the source as support\n" +
  "   - be rated central/supporting/tangential to the research question\n" +
  "4. Note publish date if available.\n\n" +
  "If the fetch fails or the page is irrelevant/paywalled, still finish with claims: [] and sourceQuality: \"unreliable\" — never end empty-handed."

const VERIFY_PROMPT = (claim, v) =>
  "## Adversarial Claim Verifier (voter " + (v + 1) + "/" + VOTES_PER_CLAIM + ")\n\n" +
  "Be SKEPTICAL. Try to REFUTE this claim. ≥" + REFUTATIONS_REQUIRED + "/" + VOTES_PER_CLAIM + " refutations kill it.\n\n" +
  "## Research question\n" + QUESTION + "\n\n" +
  "## Claim under review\n\"" + claim.claim + "\"\n\n" +
  "**Source:** " + claim.sourceUrl + " (" + claim.sourceQuality + ")\n" +
  "**Supporting quote:** \"" + claim.quote + "\"\n\n" +
  "## Checklist\n" +
  "1. Is the claim actually supported by the quote, or is it an overreach/misread?\n" +
  "2. If WebSearch is available, make at most one or two searches for contradicting evidence — does any credible source dispute or heavily qualify this? If WebSearch errors or returns nothing useful, do NOT get stuck retrying: adjudicate from the quote, the source quality, and your own knowledge.\n" +
  "3. Is the source quality sufficient for the claim's strength? (extraordinary claims need primary sources)\n" +
  "4. Is the claim outdated? (check dates — old claims about fast-moving fields are suspect)\n" +
  "5. Is this a marketing claim / press release / cherry-picked benchmark / forum speculation?\n\n" +
  "**refuted=true** if: unsupported by quote / contradicted / low-quality source for strong claim / outdated / marketing fluff.\n" +
  "**refuted=false** ONLY if: claim is well-supported, current, and source quality matches claim strength.\n" +
  "Default to refuted=true if uncertain. evidence MUST be specific."

// ─── Pipeline: search → dedup → fetch+extract (no barrier) ───
const searchResults = await pipeline(
  scope.angles,

  angle => structuredWithFallback(SEARCH_PROMPT(angle), SEARCH_SCHEMA, {
    label: "search:" + angle.label, phase: "Search"
  }).then(r => {
    if (!r) return null
    log(angle.label + ": " + r.results.length + " results")
    return { angle: angle.label, results: r.results }
  }),

  searchResult => {
    const sorted = [...searchResult.results].sort((a, b) => relRank[a.relevance] - relRank[b.relevance])
    const novel = sorted.filter(r => {
      const key = normURL(r.url)
      if (seen.has(key)) {
        dupes.push({ ...r, angle: searchResult.angle, dupOf: seen.get(key) })
        return false
      }
      if (fetchSlots <= 0 && relRank[r.relevance] >= 1) {
        budgetDropped.push({ ...r, angle: searchResult.angle })
        return false
      }
      seen.set(key, { angle: searchResult.angle, title: r.title })
      fetchSlots--
      return true
    })
    if (novel.length < searchResult.results.length) {
      log(searchResult.angle + ": " + novel.length + " novel (" + (searchResult.results.length - novel.length) + " filtered)")
    }
    return parallel(
      novel.map(source => () => {
        let host = "unknown"
        try { host = new URL(source.url).hostname.replace(/^www\./, "") } catch {}
        return structuredWithFallback(FETCH_PROMPT(source, searchResult.angle), EXTRACT_SCHEMA, {
          label: "fetch:" + host,
          phase: "Fetch",
        }).then(ext => {
          if (!ext) {
            // Even the free-text → structure fallback couldn't extract. SURFACE it as a
            // fetched-but-empty source (never silently dropped); the structural fix above
            // means this is now a genuine failure, not a one-shot StructuredOutput hiccup.
            log("fetch yielded no claims after fallback: " + source.url)
            return { url: source.url, title: source.title, angle: searchResult.angle, sourceQuality: "unreliable", claims: [] }
          }
          return {
            url: source.url, title: source.title, angle: searchResult.angle,
            sourceQuality: ext.sourceQuality, publishDate: ext.publishDate,
            claims: ext.claims.map(c => ({ ...c, sourceUrl: source.url, sourceQuality: ext.sourceQuality })),
          }
        })
      })
    )
  }
)

const allSources = searchResults.flat().filter(Boolean)
const allClaims = allSources.flatMap(s => s.claims)
const impRank = { central: 0, supporting: 1, tangential: 2 }
const qualRank = { primary: 0, secondary: 1, blog: 2, forum: 3, unreliable: 4 }

const rankedClaims = [...allClaims]
  .sort((a, b) => (impRank[a.importance] - impRank[b.importance]) || (qualRank[a.sourceQuality] - qualRank[b.sourceQuality]))
  .slice(0, MAX_VERIFY_CLAIMS)

const okSources = allSources.filter(s => s.claims.length > 0).length
const failedSources = allSources.length - okSources
log("Fetched " + allSources.length + " sources (" + okSources + " with claims, " + failedSources + " empty) → " + allClaims.length + " claims → verifying top " + rankedClaims.length)

if (rankedClaims.length === 0) {
  return {
    question: QUESTION,
    summary: "No claims extracted. " + allSources.length + " sources fetched, all empty/failed (even after the free-text→structure fallback). " + dupes.length + " URL dupes, " + budgetDropped.length + " budget-dropped.",
    findings: [], refuted: [], unverified: [],
    sources: allSources.map(s => ({ url: s.url, quality: s.sourceQuality, claimCount: s.claims.length })),
    stats: { angles: scope.angles.length, sources: allSources.length, claims: 0, dupes: dupes.length, fallbacksFired: fallbackFired, fallbackRecovered },
  }
}

// ─── Verify: 3-vote adversarial, in paced SEQUENTIAL batches ───
// Barrier here is intentional — claim pool must be fully assembled before ranking/verification.
// Batches keep the verify request rate near the fetch-phase profile that succeeds, so we don't trip
// the server rate limiter (see the 2026-06-08 follow-up note). DIRECT structured call — NO fallback
// amplification (the fallback tripled the load and recovered nothing under rate-limiting).
phase("Verify")

const judgeVote = (claim, v) =>
  agent(VERIFY_PROMPT(claim, v) + STRUCTURED_SUFFIX, {
    label: "v" + v + ":" + claim.claim.slice(0, 40), phase: "Verify", schema: VERDICT_SCHEMA,
  }).catch(() => null)   // throw (rate-limit / no-StructuredOutput) → null → abstain, NEVER a refutation

const tallyClaim = (claim, verdicts) => {
  // A vote can be null (user-skip, rate-limited, or no verdict returned) — treat as ABSTAIN, never refutation.
  const valid = verdicts.filter(Boolean)
  const refuted = valid.filter(v => v.refuted).length
  const abstained = VOTES_PER_CLAIM - valid.length
  // THREE outcomes — never conflate "couldn't adjudicate" with "refuted":
  //   confirmed : a quorum of valid votes AND fewer than REFUTATIONS_REQUIRED refuting
  //   refuted   : a quorum of valid votes that actually voted to refute (>= REFUTATIONS_REQUIRED)
  //   unverified: too few valid votes to adjudicate (rate-limit / agent errors / abstentions) — NOT refuted.
  //               These must never be reported as "refuted" (the old bug: all-abstain → "killed").
  const adjudicated = valid.length >= REFUTATIONS_REQUIRED
  const survives = adjudicated && refuted < REFUTATIONS_REQUIRED
  const outcome = !adjudicated ? "unverified" : (refuted >= REFUTATIONS_REQUIRED ? "refuted" : "confirmed")
  const mark = outcome === "confirmed" ? "✓" : (outcome === "refuted" ? "✗" : "?")
  log("\"" + claim.claim.slice(0, 50) + "…\": " + (valid.length - refuted) + "-" + refuted + (abstained > 0 ? " (" + abstained + " abstain)" : "") + " " + mark)
  return { ...claim, verdicts: valid, refutedVotes: refuted, survives, outcome }
}

const voted = []
const verifyBatches = Math.ceil(rankedClaims.length / VERIFY_BATCH)
for (let i = 0; i < rankedClaims.length; i += VERIFY_BATCH) {
  const batch = rankedClaims.slice(i, i + VERIFY_BATCH)
  log("Verify batch " + (Math.floor(i / VERIFY_BATCH) + 1) + "/" + verifyBatches + " — " + batch.length + " claims (" + (batch.length * VOTES_PER_CLAIM) + " votes)")
  const batchResults = await parallel(
    batch.map(claim => () =>
      parallel(Array.from({ length: VOTES_PER_CLAIM }, (_, v) => () => judgeVote(claim, v)))
        .then(verdicts => tallyClaim(claim, verdicts))
    )
  )
  voted.push(...batchResults.filter(Boolean))
}

const confirmed = voted.filter(c => c.outcome === "confirmed")
const killed = voted.filter(c => c.outcome === "refuted")
const unverified = voted.filter(c => c.outcome === "unverified")
log("Verify done: " + voted.length + " claims → " + confirmed.length + " confirmed, " + killed.length + " refuted, " + unverified.length + " unverified")
log("Structured-output fallback fired " + fallbackFired + "× (recovered " + fallbackRecovered + ")")

if (confirmed.length === 0) {
  // Distinguish a genuine "everything was refuted" from "the verifier never ran".
  const verifyBroke = unverified.length >= killed.length
  return {
    question: QUESTION,
    summary: verifyBroke
      ? "Verification did not complete for " + unverified.length + "/" + voted.length + " claims — the verifier agents returned no verdict (a tooling failure, typically server-side rate-limiting under load — NOT a refutation). These claims are UNVERIFIED, not refuted; the extracted claims + sources are returned below for manual judgment."
      : "All " + killed.length + " adjudicated claims were refuted by adversarial verification" + (unverified.length ? "; " + unverified.length + " more were unverified (no verdict returned)" : "") + ". Research inconclusive — sources may be low-quality or claims overstated.",
    findings: [],
    unverified: unverified.map(c => ({ claim: c.claim, quote: c.quote, source: c.sourceUrl, quality: c.sourceQuality })),
    refuted: killed.map(c => ({ claim: c.claim, vote: (c.verdicts.length - c.refutedVotes) + "-" + c.refutedVotes, source: c.sourceUrl })),
    sources: allSources.map(s => ({ url: s.url, quality: s.sourceQuality, claimCount: s.claims.length })),
    stats: { angles: scope.angles.length, sources: allSources.length, claims: allClaims.length, verified: voted.length, confirmed: 0, killed: killed.length, unverified: unverified.length, fallbacksFired: fallbackFired, fallbackRecovered },
  }
}

// ─── Synthesize ───
phase("Synthesize")
const confRank = { high: 0, medium: 1, low: 2 }
const block = confirmed.map((c, i) => {
  const best = c.verdicts.filter(v => !v.refuted).sort((a, b) => confRank[a.confidence] - confRank[b.confidence])[0]
  return "### [" + i + "] " + c.claim + "\n" +
    "Vote: " + (c.verdicts.length - c.refutedVotes) + "-" + c.refutedVotes + " · Source: " + c.sourceUrl + " (" + c.sourceQuality + ")\n" +
    "Quote: \"" + c.quote + "\"\nVerifier evidence (" + best.confidence + "): " + best.evidence + "\n"
}).join("\n")

const killedBlock = killed.length > 0
  ? "\n## Refuted claims (for transparency)\n" +
    killed.map(c => "- \"" + c.claim + "\" (" + c.sourceUrl + ", vote " + (c.verdicts.length - c.refutedVotes) + "-" + c.refutedVotes + ")").join("\n")
  : ""

const unverifiedBlock = unverified.length > 0
  ? "\n## Unverified claims (verifier returned no verdict — treat with caution, do NOT present as confirmed)\n" +
    unverified.map(c => "- \"" + c.claim + "\" (" + c.sourceUrl + ", " + c.sourceQuality + ")").join("\n")
  : ""

const report = await structuredWithFallback(
  "## Synthesis: research report\n\n" +
  "**Question:** " + QUESTION + "\n\n" +
  confirmed.length + " claims survived " + VOTES_PER_CLAIM + "-vote adversarial verification. Merge semantic duplicates and synthesize.\n\n" +
  "## Confirmed claims\n" + block + "\n" + killedBlock + "\n" + unverifiedBlock + "\n\n" +
  "## Instructions\n" +
  "1. Identify claims that say the same thing — merge them, combine their sources.\n" +
  "2. Group related claims into coherent findings. Each finding should directly address the research question.\n" +
  "3. Assign confidence per finding: high (multiple primary sources, unanimous votes), medium (secondary sources or split votes), low (single source or blog-quality).\n" +
  "4. Write a 3-5 sentence executive summary answering the research question.\n" +
  "5. Note caveats: what's uncertain, what sources were weak, what time-sensitivity applies. If any claims were unverified (no verdict returned), say so plainly.\n" +
  "6. List 2-4 open questions that emerged but weren't answered.",
  REPORT_SCHEMA,
  { label: "synthesize", phase: "Synthesize" }
)

if (!report) {
  // Synthesis skipped/errored — salvage the verified claims raw rather
  // than throwing on report.findings and discarding the whole run.
  return {
    question: QUESTION,
    summary: "Synthesis step was skipped or failed (even after fallback) — returning " + confirmed.length + " verified claims unmerged.",
    findings: [],
    confirmed: confirmed.map(c => ({ claim: c.claim, source: c.sourceUrl, quote: c.quote, vote: (c.verdicts.length - c.refutedVotes) + "-" + c.refutedVotes })),
    refuted: killed.map(c => ({ claim: c.claim, vote: (c.verdicts.length - c.refutedVotes) + "-" + c.refutedVotes, source: c.sourceUrl })),
    unverified: unverified.map(c => ({ claim: c.claim, source: c.sourceUrl, quality: c.sourceQuality })),
    sources: allSources.map(s => ({ url: s.url, quality: s.sourceQuality, claimCount: s.claims.length })),
    stats: { angles: scope.angles.length, sources: allSources.length, claims: allClaims.length, verified: voted.length, confirmed: confirmed.length, killed: killed.length, unverified: unverified.length, afterSynthesis: 0, fallbacksFired: fallbackFired, fallbackRecovered },
  }
}

return {
  question: QUESTION,
  ...report,
  refuted: killed.map(c => ({ claim: c.claim, vote: (c.verdicts.length - c.refutedVotes) + "-" + c.refutedVotes, source: c.sourceUrl })),
  unverified: unverified.map(c => ({ claim: c.claim, source: c.sourceUrl, quality: c.sourceQuality })),
  sources: allSources.map(s => ({ url: s.url, quality: s.sourceQuality, angle: s.angle, claimCount: s.claims.length })),
  stats: {
    angles: scope.angles.length,
    sourcesFetched: allSources.length,
    claimsExtracted: allClaims.length,
    claimsVerified: voted.length,
    confirmed: confirmed.length,
    killed: killed.length,
    unverified: unverified.length,
    afterSynthesis: report.findings.length,
    urlDupes: dupes.length,
    budgetDropped: budgetDropped.length,
    fallbacksFired: fallbackFired,
    fallbackRecovered,
  },
}
