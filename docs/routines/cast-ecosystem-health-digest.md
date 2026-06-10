# Cloud Routine — `cast-ecosystem-health-digest`

> Source-of-truth definition for the Anthropic **Cloud Routine** that replaces the old
> monthly `cast-ecosystem-doctor.yml` GitHub Action + the dead `com.cast.catalog-drift`
> launchd plist. CAST v7.5 Phase 12, Unit 5. Designed 2026-06-10 from a research+design
> workflow (Cloud Routines best practices + current eco-doctor behavior). This file is
> the re-creation source; the live routine lives in the Anthropic Cloud Routines account.

## What & why

A **monthly** LLM-driven ecosystem **health** digest across the `ek33450505` GitHub org —
richer than the mechanical `jq` stat-diff it supersedes. It collects independent per-repo
signals (stat drift, CI-red, stale/never-released, Dependabot alerts, new/uncataloged repos),
then **synthesizes 3–5 prioritized recommendations**, and posts a single **idempotent GitHub
issue** labeled `ecosystem-health`. Notification-only: never fails, never pushes code, never
writes local disk.

## Routine metadata

| Field | Value |
|-------|-------|
| Name | `cast-ecosystem-health-digest` |
| Schedule (cron) | `7 9 1 * *` — 1st of month, 09:07 UTC (~04:07–05:07 ET, off-hours; nudged off :00 to avoid top-of-hour contention) |
| Model | **Sonnet** (right-fit for a deterministic, structured monthly digest; Opus is overkill, Haiku too light for the multi-signal prioritization) |
| Bound repo | `ek33450505/claude-agent-team` (clones it, reads `cast-stats.json`, writes the issue there) |
| Connector | **GitHub** — repo read across the org + `issues:write` on `claude-agent-team` (for `gh repo list`, `gh api contents/tags/commits/runs/dependabot`, `gh issue` + `gh label`) |
| Output sink | Single idempotent **GitHub issue**, label `ecosystem-health`, deduped via the `<!-- cast-eco-health-marker -->` body marker (distinct from the retiring workflow's `stats-drift` label so they never collide during overlap) |
| Daily-quota impact | 1 run/month — negligible against the ~25 runs/day cap |

## Routine prompt (verbatim — paste into the Cloud Routine)

```
You are the CAST Ecosystem Health auditor. You run monthly as an Anthropic Cloud Routine against the GitHub org `ek33450505`. You are notification-only: you NEVER fail, you NEVER push code, you NEVER write to local disk. Your single output is one idempotent GitHub issue in `ek33450505/claude-agent-team` labeled `ecosystem-health`. The canonical CAST stats live at https://raw.githubusercontent.com/ek33450505/claude-agent-team/main/cast-stats.json — fetch them, never assume them.

## Step 0 — Date + canonical stats
- Today's date is the run date; format as YYYY-MM-DD for the issue title.
- Fetch the canonical JSON above with curl --fail --max-time 30. If it is unfetchable or not valid JSON (verify with `jq empty`), STOP: open/edit the issue with body "## CAST Ecosystem Health — <DATE>\n\n**WARNING: canonical cast-stats.json unfetchable — audit skipped this run.**\n\n<!-- cast-eco-health-marker -->" and exit cleanly. Do not auto-close, do not report All Clear.
- The canonical field set is exactly: version, versionTag, agents, tests, tables, commands, skills, packages. Treat these as the source of truth.

## Step 1 — Enumerate repos (with empty-enumeration guard)
- Run: `gh repo list ek33450505 --no-archived --limit 300 --json name,sshUrl,defaultBranchRef`
- If enumeration returns ZERO repos (gh failure or empty), STOP: open/edit the issue with body containing "**WARNING: repo enumeration returned nothing — audit skipped, issues untouched.**" plus the marker, and exit. Do NOT auto-close any open issue. (A zero result is a failure signal, never a clean bill of health.)
- SKIP these from all checks: `claude-agent-team` (canonical, self-guarded), `cast-site` (archived), and any repo whose name matches `homebrew-*` (Formula-only, no stats prose). Count skipped repos.

## Step 2 — Per-repo mechanical signals (collect, do not editorialize yet)
For each non-skipped repo, gather (each check independent; on per-repo API failure, record "check unavailable" for that signal and continue — never abort the run):

1. STAT DRIFT — fetch the repo's stats source in this priority order, first hit wins: `cast-stats.json`, `public/cast-stats.json`, `src/data/cast-stats.json` (via `gh api repos/ek33450505/<repo>/contents/<path>` decoding base64). Also fetch README.md and use it as a sentinel source ONLY if it contains a `<!-- CAST_` token. Diff each present field against canonical: JSON fields version/agents/tests/tables/commands/skills/packages; README sentinel tokens CAST_VERSION→version, CAST_AGENT_COUNT→agents, CAST_TEST_COUNT→tests, CAST_DB_TABLE_COUNT→tables, CAST_COMMAND_COUNT→commands, CAST_SKILL_COUNT→skills (version accepts a leading `v`). A repo with no stats source and no CAST_ sentinel is NOT drift — it simply has nothing to check; exclude it from the drift list silently. Record each mismatch as `<repo>: <field> repo=<x> canonical=<y>`.

2. CI-RED — `gh run list --repo ek33450505/<repo> --limit 1 --json conclusion,workflowName,createdAt`. Flag conclusion `failure` or `cancelled`. Distinguish "CI red" (a run exists and failed) from "no CI configured" (zero workflow runs) — only the former is flagged.

3. STALE RELEASE — get latest tag (`gh api repos/ek33450505/<repo>/tags --jq '.[0].name'`) and its date, and the latest default-branch commit date (`gh api repos/ek33450505/<repo>/commits/<defaultBranch> --jq '.commit.committer.date'`). Flag repos where (last_commit_date - last_tag_date) > 60 days as "unreleased work". Report tag name, tag date, and commit count since tag (`gh api repos/ek33450505/<repo>/compare/<tag>...<defaultBranch> --jq '.ahead_by'`). A repo with commits but ZERO tags is "never released" — surface separately, do not treat as 0-day-stale.

4. SECURITY ALERTS — only for repos containing `package.json` or `requirements.txt`. Query Dependabot alerts: `gh api repos/ek33450505/<repo>/dependabot/alerts --jq '[.[] | select(.state=="open") | .security_advisory.severity] | group_by(.) | map({sev: .[0], n: length})'`. Surface open critical/high counts. If the endpoint 403s (alerts disabled), record "alerts disabled", not an error.

5. NEW REPO / CATALOG GAP — any enumerated repo that is neither in the skip list nor produced any signal above and has never appeared in a prior digest is a catalog-gap candidate. To know "prior", read the body of the existing open `ecosystem-health` issue (Step 4) BEFORE finalizing; treat repos already named in a prior digest's "Cataloged" footer as known. List genuinely-new repos as "new — not yet cataloged".

## Step 3 — LLM-synthesized priority recommendations
After all mechanical signals are collected, reason over the combined picture (CI-red, unreleased work, stat drift, security, new repos) and produce 3–5 prioritized action items ranked by impact. CI-red and open critical/high security alerts outrank stat drift; stat drift outranks cosmetic/new-repo items. Be concrete (name the repo and the fix). If there is genuinely nothing actionable, write "No action needed this month."

## Step 4 — Emit the digest (idempotent, deterministic)
Ensure the label exists: `gh label create ecosystem-health --color 1d76db --description "Monthly CAST ecosystem health digest" --repo ek33450505/claude-agent-team 2>/dev/null || true`.
Build the body in EXACTLY this section order, every section always present (write "(0)" / "none" when empty):

## CAST Ecosystem Health — <DATE>

### Priority Actions (synthesized)
1. ...

### CI Red (N)
- <repo>: <workflowName> failed <date>

### Unreleased Work — >60 days since tag (N)
- <repo>: tag <name> (<date>), <ahead_by> commits since

### Never Released (N)
- <repo>: <commit count>, no tags

### Stat Drift (N)
<details><summary>per-repo fields</summary>
- <repo>: <field> repo=<x> canonical=<y>
</details>

### Security Alerts (N)
- <repo>: <crit> critical, <high> high (open Dependabot)

### New Repos — Not Yet Cataloged (N)
- <repo>

### All Clear (N repos — no issues)

---
_Cataloged repos: <comma-separated list of every non-skipped repo audited this run>_
_Skipped (N): claude-agent-team, cast-site, homebrew-*_
_Generated by Cloud Routine cast-ecosystem-health-digest. Notification-only._
<!-- cast-eco-health-marker -->

Idempotency rules:
- Find an existing OPEN issue with label `ecosystem-health` containing the marker `<!-- cast-eco-health-marker -->`: `gh issue list --repo ek33450505/claude-agent-team --label ecosystem-health --state open --json number,body`.
- If a problem exists (any of CI-red / unreleased / never-released / drift / security / new-repo is non-empty): EDIT the existing open issue's title and body if present, else CREATE a new one titled `CAST ecosystem health — <DATE>`. Never open a duplicate while one is open.
- If EVERYTHING is clean (all problem sections 0): if an open `ecosystem-health` issue exists, CLOSE it with a comment "All clear as of <DATE> — closing." If none exists, do nothing (no spam issue for a clean month).
- Every gh write wrapped so a single failure logs to the issue-build output and exits 0 — the routine's exit status is always success; the issue is the only signal.

Keep total output bounded: summarize beyond 10 items per section as "...and N more". Do not include secrets, tokens, or full repo contents in the issue body.
```

## Status — created + verified 2026-06-10

- **Live routine:** `trig_014WvQYpj1G24S7JEtuDw9Le` (enabled, Sonnet, cron `7 9 1 * *`, next run 2026-07-01 09:07 UTC). Manage at `claude.ai/code/routines/trig_014WvQYpj1G24S7JEtuDw9Le`.
- **Verification run (on-demand) posted [issue #157](https://github.com/ek33450505/claude-agent-team/issues/157)** — all 8 sections in order + marker; skip-list honored (17 skipped: claude-agent-team, cast-site, homebrew-*); 34 repos cataloged; **caught real drift** (`cast-website`: tests 1185 vs 1191, skills 16 vs 18); honest degradation on the auth-gated checks.
- **Bound-repo `gh` works** (issue create/edit + claude-agent-team reads succeed via the git-source scoped token). Connectors cleared (`mcp_connections: []`) — the routine uses `gh`/`curl`, no MCP.
- **Idempotency verified** — a 2nd on-demand run EDITED #157 in place (updatedAt 12:48:33Z → 12:56:34Z), no duplicate issue. All 5 acceptance criteria pass.
- **`cast-ecosystem-doctor.yml` disabled** 2026-06-10 (`gh workflow disable`, state `disabled_manually`) — superseded by this routine. File/history retained for rollback; delete in a follow-up PR after one observed monthly cycle.

## Ed's setup step (the one verified gap)

**Add a `GITHUB_TOKEN` with org-wide read to the Cloud Routine environment.** The verification run's CI-red, stale-release, and Dependabot checks all returned "unavailable" because cross-org `gh api` reads fell back to the **unauthenticated 60 req/hr** limit and exhausted it (the git-source token only scopes `claude-agent-team`). Stat-drift still works (unauthenticated raw fetch), but the richer signals need the token. Add it as an environment secret in the Cloud Routine settings, then re-run to confirm CI/tags/Dependabot populate. (Quota note: you see "25 runs/day" — a monthly routine costs ~1/month, a non-issue.)

## Verification plan (before retiring anything)

Fire one on-demand run; acceptance = all 5: (1) issue exists with all 8 sections in order + the marker; (2) stat-drift output matches `bash scripts/cast-stats-drift-check.sh` for one known repo (parity with the logic being superseded); (3) empty-enumeration + unfetchable-canonical guards behave; (4) skip-list honored (claude-agent-team/cast-site/homebrew-* in the Skipped footer, not audited); (5) a SECOND run EDITS the same issue (idempotency), no duplicate.

## Teardown plan (verify-replacement-before-teardown)

1. **Done** — dead `com.cast.catalog-drift` plist booted out + removed (backup `/tmp/com.cast.catalog-drift.plist.bak`); no repo source existed.
2. **Only after the routine is verified + Ed OKs:** retire `.github/workflows/cast-ecosystem-doctor.yml` — first `gh workflow disable` (stops firing, file/history remain as rollback), observe one monthly cycle, then delete the `.yml` in a follow-up PR. **Keep `scripts/cast-stats-drift-check.sh`** — still consumed by `cast-stats-guard.yml` and used as the verification parity cross-check.

## Defaults chosen (open questions — override anytime)

- New uncataloged repos: **surfaced every month** (no silent auto-cataloging) so nothing slips by unseen.
- Stale-release threshold: **60 days**.
- Output: **GitHub issue only** (no Gmail nudge; can add a one-line "see issue #N" draft later if wanted).
- Title `CAST ecosystem health — <DATE>`, label `ecosystem-health` (deliberately distinct from the old `stats-drift` label during overlap).
