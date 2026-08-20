# v10 Attribution Gap — Lifecycle Investigation

**Date:** 2026-08-20
**Scope:** Measurement + source analysis only. No fixes, no edits, no writes to the live DB.
**Window used throughout:** `agent_runs` full table span is `2026-07-21T12:25:43Z` → `2026-08-20T18:42:17Z` (3265 rows). All figures below are the rolling 30-day window (`started_at >= datetime('now','-30 days')`), captured 2026-08-20. **Re-run the SQL before citing — this window prunes.**
**Related:** sibling doc `research/v10-attribution-gap-producer.md` (not read/touched here, per instruction).

---

## Q1: Does `cast_subagent_stop.py` correlate to empty-`session_id`/`agent_id` rows?

**ESTABLISHED — it CANNOT match them, and the reason is more specific than "no correlating key exists."**

### The correlation keys (exact)

`cast_subagent_stop.py` has two correlation points that share identical logic (`stage0_fast_write`, `scripts/cast_subagent_stop.py:512-529`, and the enrichment pass, `scripts/cast_subagent_stop.py:786-834`):

```python
if _fast_agent_id:                      # truthy check — '' counts as absent
    "SELECT MIN(id) FROM agent_runs WHERE status='running' AND agent_id=?", (_fast_agent_id,)
else:
    "SELECT MIN(id) FROM agent_runs WHERE status='running' AND agent=? AND session_id=?", (agent, sess)
```
`agent_id` path is preferred when the Stop payload carries a non-empty `agent_id`; otherwise it falls back to `agent` + `session_id`, always taking the `MIN(id)` (oldest matching `running` row — a FIFO heuristic, not a unique key).

### Why an empty-session_id/agent_id START row cannot be matched

This is a **type-representation mismatch**, not merely absent data, verified directly:

- **On INSERT** (`scripts/cast-subagent-start-hook.sh:150`): `sess = _sess_raw if _sess_raw else None` — an empty session_id is stored as SQL **`NULL`**. `agent_id` has no such normalization (`os.environ.get('CAST_START_AGENT_ID', '')`) — it is stored as a literal **empty string `''`**.
- **On STOP correlation** (`cast_subagent_stop.py:388`): `session_id = data.get("session_id") or ""` — `ctx.session_id` is **always a string**, never `None`. The bound parameter for `session_id=?` is therefore always `''` when absent, never `NULL`.
- SQL equality: `NULL = ''` is never true (SQLite evaluates to `NULL`, which is falsy in a `WHERE`). Verified directly:
  ```
  sqlite3 :memory: "CREATE TABLE t(a TEXT, s TEXT); INSERT INTO t VALUES ('unknown', NULL);
                     SELECT COUNT(*) FROM t WHERE a='unknown' AND s='';"   -- 0
  sqlite3 :memory: "... SELECT COUNT(*) FROM t WHERE a='unknown' AND s IS NULL;"  -- 1
  ```
- The `agent_id` path is likewise closed: the started row's `agent_id` is stored as `''`, and `if _fast_agent_id:` treats `''` as falsy, so even if a genuine Stop event *did* carry an `agent_id`, it would route to the `agent`+`session_id` fallback anyway — which then fails as above.

**Confirmed against the live rows** (all 19 `agent='unknown'` rows in the 30-day window):
```sql
SELECT status, (session_id IS NULL) sess_null, (agent_id='') aid_empty, COUNT(*)
FROM agent_runs WHERE agent='unknown' AND started_at >= datetime('now','-30 days')
GROUP BY 1,2,3;
-- abandoned|1|1|2   failed|1|1|6   running|1|1|11
```
Every row: `session_id IS NULL`, `agent_id=''`. Both correlation paths are structurally closed for this exact shape, independent of whatever caused the payload-parse failure at start time.

**Does this refute the leading hypothesis?** No — it *sharpens* it. The leading hypothesis ("these rows can't be matched") is correct, but not because there's "no information" — it's because the writer and the matcher use **two different null-conventions for the same logical absence** (`NULL` vs `''`), so even a hypothetical Stop event carrying the *same* missing-ness would not close the loop. This is a second, independent bug from whatever the producer-side investigation is chasing (payload parse failure) — it means fixing the parse failure alone would not retroactively let old broken rows get matched; a live/future Stop event still could not find them without also normalizing the two representations.

---

## Q2: Who transitions these rows to `failed`/`abandoned`, and what do they actually write?

**ESTABLISHED, from reading the code that runs TODAY (2026-08-20), not from any comment.**

Three independent writers touch `agent_runs.status` for stale `running` rows — the observed statuses (`failed`, `abandoned`, never `crashed`) come from **two different writers with two different terminal labels**:

| Writer | Status written | WHERE clause | Threshold |
|---|---|---|---|
| `scripts/cast-abandon-stale-runs.py:50-52` | `'abandoned'` | `status='running'` (+ `abandoned_at` set, **no `ended_at`**) | `CAST_ABANDON_STALE_HOURS` (default 2h) |
| `scripts/cast-maintenance.sh:54` | `'failed'` | `status='running' AND datetime(started_at) < datetime('now','-2 hours')` (no agent/session predicate) | hardcoded 2h |
| `scripts/cast-session-end.sh:268` | `'failed'` | `status='running' AND started_at < datetime('now','-2 hours')` (no agent/session predicate) | hardcoded 2h |

None of these three WHERE clauses filter on `agent_id` or `session_id` — they all match purely on `status='running'` + staleness, so an `agent='unknown'`/`session_id IS NULL` row is fully eligible and gets swept exactly like any normal orphaned row. **This is why the row transitions at all despite being unmatchable by `cast_subagent_stop.py`: these three sweepers don't need to correlate — they just reap anything stuck in `running` past the threshold.**

### The `'crashed'` comment claim — could not locate it

I grepped the full repo (`scripts/`, `plugin/scripts/`, `docs/`, `agents/`, `tests/`) for any comment asserting `agent_runs` gets `status='crashed'`. **I did not find one.** What I did find is that `'crashed'` is real, but it applies only to the **`sessions`** table, in the *same* file (`cast-abandon-stale-runs.py` Step 2, lines 452-463: `UPDATE ... SET status='crashed' ... WHERE status='active'`, 4h default via `CAST_SESSION_CRASH_HOURS`), and the script's own docstring (lines 1-45) states this correctly and explicitly ("Step 1 ... flipped to 'abandoned'" / "Step 2 ... flipped to 'crashed'"). A closely-related comment in `scripts/cast-commit-provenance.py:53` also correctly scopes `'crashed'` to `sessions`, not `agent_runs`.
**Conclusion:** either the comment referenced in the dispatch prompt does not currently exist in this repo state, or it lives somewhere I did not search (agent-memory or an external note). The behavior on disk today is unambiguous: `agent_runs` → `'abandoned'` or `'failed'`; `sessions` → `'crashed'`. No writer sets `agent_runs.status='crashed'` anywhere in `scripts/` or `plugin/scripts/`.

### `response` field: matched vs silent-failure vs stale-version

Both `'failed'`-writers use `response=COALESCE(response, '[NO RESPONSE — SubagentStop never fired; reaped by <script> after 2h stale running]')`. On the live 6 `failed` + 2 `abandoned` unknown rows, **`response` is `NULL`** (verified via `typeof(response)='null'`), i.e. the marker text was **not** written, despite the UPDATE having run (status did change).

- **INFERRED (temporal correlation, not a captured log of which invocation ran):** the `response=COALESCE(...)` clause was added to both scripts in commit `55b1106` (2026-08-18 13:46:17 -0400, "CAST v10 continuity wave #365"). All 6 `failed` rows have `ended_at` between 2026-08-04 and 2026-08-16 — **before** that commit. The 2 `abandoned` rows (which never get `response` written by design — `cast-abandon-stale-runs.py`'s Step-1 UPDATE never touches `response`) transitioned 2026-08-16, also pre-commit. This is consistent with "an older script version reaped these rows before the marker-write logic existed" rather than a silent `db_write` failure — but I have not proven which exact script/version fired (no per-run audit log for this sweep exists to check against). Flag this as the most likely explanation, not a certainty.
- I found **no evidence of a silent write failure** on this path: neither writer uses the `db_write()` Python abstraction (both are raw `sqlite3`/`cast_sqlite` shell calls), so the "dropped/renamed column, `db_write` fails silently" failure mode documented elsewhere in the record is **structurally inapplicable here** (no `db_write()` call exists in either path) — corroborated by a prior session-distiller memory note (`_pending/feedback_best-evidence-cast-abandon-stale-runs-py-s.md`, low confidence, unreviewed) making the same observation independently.

---

## Q3: Is 19 rows the true blast radius?

**ESTABLISHED counts, 30-day window, reproducible via the SQL below.** Roster = the 27 files under `agents/core/*.md`.

| Shape | Rows (30d) | Distinct names | Notes |
|---|---:|---:|---|
| `agent='unknown'` (the reported gap) | **19** | 1 | All: `session_id IS NULL`, `agent_id=''`. Never `DONE`. |
| Non-`unknown` agent with NULL/empty `session_id` | **0** | — | This specific failure mode does **not** recur under any other agent name in-window. |
| `agent_id IS NULL` (any status) | **0** | — | ⚠️ Contradicts the prior audit's cited "~27% NULL agent_id" — that figure is from a different/older/pruned window and should **not** be re-cited (matches the standing memory warning). In the *current* window `agent_id` is either a real value or `''`, never SQL `NULL`. |
| `agent_id=''` (empty string, not NULL) | **19** | 1 | Identical row-set to the `unknown` bucket above — same 19 rows. |
| Exact roster match + `'unknown'` | 1,747 | 28 | Normal, attributable dispatches. |
| `__label` custom names (`agent LIKE '%__%'`) | 433 | many | Per the standing `__label` convention — prefix before `__` recoverable to a type. |
| `__label` rows whose prefix is **not** in the 27-file roster | 11 | 1 (`general-purpose__*`) | `general-purpose` is a real Claude Code built-in subagent type, just not a CAST roster file — recoverable, not a true gap. |
| Custom name, **no** `__` separator, not roster, not `unknown` | **1,087** | 372 | See breakdown below. |

Breakdown of the 1,087 no-`__` custom-name rows:
```sql
SELECT agent, COUNT(*) c FROM agent_runs
WHERE started_at >= datetime('now','-30 days') AND agent != 'unknown'
  AND agent NOT LIKE '%__%' AND agent NOT IN (<27 roster names>)
GROUP BY agent ORDER BY c DESC LIMIT 10;
-- workflow-subagent 400 | general-purpose 65 | Explore 18 | audit-bugs 7 | fork 7 |
-- sec-c2 7 | commit-agent 6 | hero-writer 6 | unit4-doctor-redaction-check 6 | unit5-routing-table-removal 6
```
- **483 rows** (`workflow-subagent` 400 + `general-purpose` 65 + `Explore` 18) are legitimate **Claude Code built-in** agent-type strings, not CAST roster names — correctly attributable by name, just outside the 27-file roster set. Not a gap.
- **604 rows / 372 distinct names** (e.g. `GA1`, `va-fxbg1`, `econ-aws`, `comm-VA1`, `unit4-doctor-redaction-check`) are ad-hoc `name=` dispatch labels with **no `__` separator at all** — these are **permanently unrecoverable to a roster type by string-parsing**, per the standing memory rule that a custom `name` overwrites `agent_type` in the hook payload with no separate carrier key. All 604 of these rows **do** have a real `session_id` (verified: `0` of them have NULL/empty `session_id`) — so this is a **naming-hygiene gap** (can't roll up cost/attribution to a roster type), structurally distinct from the NULL/`''`-mismatch bug in Q1/Q19-rows, which is a **data-loss gap** (can't even find the row at Stop time). Note `~/.claude/cast.db` is shared globally across all of Ed's projects (per `stack-reference` skill), so many of these 372 names likely belong to other repos' project-specific dispatch conventions, not this repo.

**Answer: No, 19 is not the true blast radius of "unattributable" in the broad sense, but it IS the full blast radius of the specific mechanism under investigation** (SubagentStart payload-parse failure → unmatchable NULL/`''` row, never reaching `DONE`). The 604-row no-`__` custom-name shape is a much larger but *mechanistically different* and *already-documented* gap (naming convention, not a hook bug) — rows in that bucket keep their `session_id` and can reach `DONE` normally.

Reproduce:
```sql
-- span
SELECT MIN(started_at), MAX(started_at) FROM agent_runs;
-- Q3 table rows, run each cell's query with started_at >= datetime('now','-30 days')
```

---

## Summary

1. **Q1 — ESTABLISHED:** `cast_subagent_stop.py` cannot match these rows, for a precise reason: the start-hook stores an absent `session_id` as SQL `NULL` but the stop-processor always binds an empty **string** (`''`) for absent `session_id`, and `NULL = ''` is never true in SQLite. The `agent_id` path is also closed because the stored `agent_id` is `''` (falsy), which routes to the broken `session_id` path regardless. This is a distinct bug from the producer-side parse failure — fixing the parse failure alone will not let a Stop event retroactively match old broken rows.
2. **Q2 — ESTABLISHED:** Three writers reap stale `running` rows without any agent/session correlation requirement — `cast-abandon-stale-runs.py` (→ `'abandoned'`), `cast-maintenance.sh` and `cast-session-end.sh` (both → `'failed'`). No writer sets `agent_runs.status='crashed'` anywhere in the current repo; `'crashed'` is real but scoped only to the `sessions` table. The `'crashed'`-comment claim in the dispatch could not be located on disk. The missing `response` marker on the 6 `failed` rows is most likely (INFERRED, not proven) a pre-2026-08-18 versioning artifact, not a silent write failure — neither writer uses the `db_write()` abstraction implicated in that failure class.
3. **Q3 — ESTABLISHED:** 19 rows is the exact blast radius of the NULL/`''`-mismatch mechanism (confirmed: 0 non-`unknown` rows share it). A much larger, mechanistically separate gap exists: 604 rows / 372 distinct names use ad-hoc `name=` labels with no `__` separator and are unrecoverable to a roster type by parsing — but those rows retain valid `session_id`s and are not otherwise stuck/orphaned.

## Handoff
files_changed: research/v10-attribution-gap-lifecycle.md
status: DONE
blockers: none
key_decisions: Treated the 604-row no-`__` custom-name shape as a separate finding from the 19-row NULL/`''` bug, since they have different root causes (naming hygiene vs. hook data-type mismatch) and different consequences (recoverable session_id vs. none). Did not locate the `'crashed'`-comment claim on disk after a full-repo grep — reported as not-found rather than guessing at its location.
next_agent_needs: If a fix is authorized, it targets `cast_subagent_stop.py`'s `session_id` binding (bind `NULL` via `IS NULL` when absent, matching the start-hook's storage convention) — but that only helps FUTURE parse-failure rows; it cannot retroactively fix rows already stuck (they'd need a one-time backfill sweep, out of scope here).

Status: DONE
Summary: Q1 — NULL(session_id)-vs-''(bound param) mismatch structurally blocks matching, not merely missing data; Q2 — 3 writers (abandon/maintenance/session-end) reap without correlation, none write 'crashed' to agent_runs (comment claim not found), missing response marker likely a pre-2026-08-18 versioning artifact; Q3 — 19 rows is the exact NULL/'' blast radius, but a separate 604-row/372-name no-`__` custom-naming gap exists (session_id intact, different mechanism).
Files changed: research/v10-attribution-gap-lifecycle.md
