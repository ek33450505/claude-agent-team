---
name: deep-research
description: Deep research harness — fan-out web searches, fetch sources, adversarially verify claims, synthesize a cited report. When the user wants a deep, multi-source, fact-checked research report on any topic. BEFORE invoking, check if the question is specific enough to research directly — if underspecified (e.g., "what car to buy" without budget/use-case/region), ask 2-3 clarifying questions to narrow scope. Then pass the refined question as args, weaving the answers in.
user-invocable: true
allowed-tools: [Workflow, Read]
---

# Deep Research Skill

A multi-agent research harness: it decomposes a question into search angles, fans out
parallel web searches, fetches and extracts falsifiable claims from sources, **adversarially
verifies** every claim with a 3-vote skeptic panel, and synthesizes a cited report.

The workflow lives in [`deep-research.workflow.js`](deep-research.workflow.js) next to this
file. It is the **single source of truth** for the harness — edit it there, then (if you keep
a repo copy) run `bash install.sh` to redeploy.

## Usage

```
/deep-research <your research question>
```

## How to run it

1. **Scope-check first.** If the question is underspecified (missing budget, region, use-case,
   timeframe, etc.), ask the user **2-3 clarifying questions** before running. Then fold the
   answers into a single refined question string.

2. **Invoke the workflow** via the Workflow tool, pointing `scriptPath` at the workflow file in
   this skill's directory and passing the refined question as `args`:

   ```
   Workflow({
     scriptPath: "~/.claude/skills/deep-research/deep-research.workflow.js",   // expand ~ to $HOME
     args: "<the refined research question>"
   })
   ```

   Pass the question as a plain string in `args` (not JSON-encoded). The workflow reads it via the
   global `args`. This skill's instruction to call Workflow is itself the explicit opt-in for
   multi-agent orchestration.

3. **Relay the result.** The workflow returns `{ summary, findings, refuted, unverified, sources,
   stats }`. Present the summary and findings with their sources; surface `unverified` claims
   clearly tagged as **unverified** (verification couldn't render a verdict — NOT refuted), and
   keep `refuted` claims in a transparency section.

## Output contract (important)

The harness reports **three** claim outcomes, never two:

- **confirmed** — a quorum of valid votes, fewer than 2 refuting.
- **refuted** — a quorum of valid votes with ≥2 actually voting to refute.
- **unverified** — too few valid verdicts to adjudicate (agent/tooling failure or abstentions).
  These are returned with their sources and an explicit "unverified" tag. **Never present an
  unverified claim as confirmed, and never report it as refuted.** A run where verification
  couldn't execute returns the extracted claims marked unverified — it does **not** collapse to an
  empty findings list with a "refuted" headline.

`stats.fallbacksFired` / `stats.fallbackRecovered` show how often a low-fan-out subagent (scope/
search/fetch/synthesize) failed to emit structured output and the free-text→structure fallback
recovered it. A high `unverified` count with `confirmed: 0` means verification couldn't run (usually
server load) — say so plainly when relaying results; do **not** dress it up as a finding.

## Design notes

- **Cost scales with the question, dialed back for load (2026-06-08).** Default fan-out: 5 angles,
  ≤10 fetched sources, top-12 claims × 3 verifier votes (~50–65 subagent calls). Verify is the
  heaviest phase, so it runs in **sequential batches** (`VERIFY_BATCH` claims each, direct call) to
  pace requests under the server's transient rate limiter — each batch fully drains before the next.
- **Resilience, by phase:**
  - *Verify* uses a **direct** structured call with **no** fallback amplification. A live post-mortem
    (run wf_2b84c096) showed the free-text→structure fallback only multiplied load under rate-limiting
    (75 votes → 225 agents, 0 recovered). A failed/rate-limited vote → abstain → the claim is
    **unverified** (never refuted) — honest degradation, not a fabricated verdict.
  - *Scope / Search / Fetch / Synthesize* (low fan-out) keep `structuredWithFallback()`: if a subagent
    does its web work then ends without StructuredOutput, the work is re-run as a free-text pass and a
    structure-only agent renders it — so one hiccup doesn't drop a good source.
- **Honest failure is the contract.** When the service is busy the harness returns *unverified* claims
  and says so; it does not fabricate confirmations or refutations. See the two 2026-06-08 post-mortem
  notes in the workflow header.
