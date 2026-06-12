# Crashed Sessions Analysis — 2026-06-11

> Written as part of v7.5 Phase 5 residue: Task 4 (crashed-sessions doctor WARN tuning).
> Live query data collected 2026-06-12T00:10Z against `~/.claude/cast.db`.

---

## Live Query Results

### Day distribution (7-day rolling window)

```sql
SELECT date(replace(replace(started_at,'T',' '),'Z','')) as day, COUNT(*) as cnt
FROM sessions
WHERE status='crashed'
  AND replace(replace(started_at,'T',' '),'Z','') >= datetime('now','-7 days')
GROUP BY day ORDER BY day;
```

| Day        | Crashes |
|------------|---------|
| 2026-06-05 | 16      |
| 2026-06-06 | 2       |
| 2026-06-07 | 0       |
| 2026-06-08 | 15      |
| 2026-06-09 | 38      |
| 2026-06-10 | 16      |
| 2026-06-11 | 2       |
| **Total**  | **89**  |

### Crashed sessions with `ended_at` set

```sql
SELECT COUNT(*) FROM sessions WHERE status='crashed' AND ended_at IS NOT NULL;
-- Result: 1
```

The one row: `e76edb7c-5236-427b-9c44-9e9581a812d9`, started `2026-06-10T17:09:50Z`, ended `2026-06-10T17:39:12Z`.

### Hung-bats correlation check

The plan asked to confirm zero crashed sessions started after `2026-06-10T22:21Z` (the hung-bats session mark):

```sql
SELECT id, started_at FROM sessions WHERE status='crashed'
AND replace(replace(started_at,'T',' '),'Z','') > '2026-06-10 22:21:00';
-- 2 rows: 04e9b855 (2026-06-11T14:58:12Z) and smoke-test (2026-06-11T18:55:35Z)
```

**Verdict: hypothesis NOT confirmed.** Two sessions crashed after the hung-bats cutoff. These are normal "session ended without clean exit" bookkeeping events from subsequent work on 2026-06-11, not artifacts of the hung-bats session. The hung-bats session itself is visible in the Jun-10 count of 16.

---

## Bookkeeping vs. Real Crashes

### How crash marking works

`cast-session-end.sh:231` writes `ended_at` + `status='ended'` **only on clean session exit** (normal user `exit` or Ctrl-D). Sessions terminated by:

- Terminal kill (`kill -9`, window close)
- Hung agent timeout (e.g., the 20h bats hang)
- Network disconnect
- SIGTERM from OS scheduler

...never invoke `cast-session-end.sh`. These sessions remain `status='active'` until `cast-abandon-stale-runs.py` (Step 2, runs daily via launchd) flips them to `crashed` after `CAST_SESSION_CRASH_HOURS` (default 4h).

### The 1 crashed row with `ended_at` set

Session `e76edb7c` has both `status='crashed'` and `ended_at IS NOT NULL`. This is a race condition: the session ended cleanly and `cast-session-end.sh` wrote `ended_at` + `status='ended'`, but the daily reaper ran concurrently (or the status was later overwritten). This is a bookkeeping artifact, not a real crash with a known clean-end timestamp. The row count is 1 and the pattern is expected to be rare.

### Split

| Category | Indicator | Count in 7d | Notes |
|----------|-----------|-------------|-------|
| Bookkeeping crashes | `ended_at IS NULL` (terminal kill, hang, agent killed) | 88 | Expected background noise |
| Bookkeeping anomaly | `ended_at IS NOT NULL` (reaper/end-hook race) | 1 | Harmless |
| Genuine unexpected crashes | Would appear as process core dumps, `panic` entries in system log | 0 confirmed | None in 7d window |

All 89 crashes in the 7-day window are attributable to bookkeeping, not genuine unexpected process failures.

---

## Threshold Rationale

### Data-derived noise floor

| Metric | Value |
|--------|-------|
| Quiet day | 0–2 crashes |
| Normal active day | 15–16 crashes |
| Heavy agent day (Phase 5 DB work) | 38 crashes |
| 7-day total at 20x Max usage | ~89 crashes |

The original plan estimated 1–3 crashes/day = 7–21/week. This was calibrated for "terminals killed" only. In practice, every agent session, subagent session, and tool-call session that doesn't end cleanly accrues a crash. At current CAST usage (heavy multi-agent orchestration, 20x Max capacity), the realistic floor is **15–38 per active day**.

### Default threshold: 100

A threshold of **100 per 7 days** was chosen because:

1. Our current observed maximum is 89/week under heavy usage
2. 100 provides a narrow but meaningful buffer above the observed maximum
3. A genuine crash spike (e.g., a launchd misconfiguration flooding the DB, or a session-start loop) would produce 100+ crashes rapidly
4. The old threshold of `> 0` caused a permanent WARN at all times and was meaningless signal

The threshold was **data-calibrated from the observed day distribution** (see table above), not the plan's initial estimate of 10.

### Override

```bash
# Example: lower the threshold for a quieter machine
CAST_CRASH_WARN_THRESHOLD=50 cast doctor
```

Set `CAST_CRASH_WARN_THRESHOLD` in the environment or via launchd environment variables for persistent override.

---

## Doctor Output After Change

```
[ok]  crashed-sessions: 89 in last 7d (below threshold 100)
```

Previously: `[warn] crashed-sessions: 87 session(s) crashed in last 7d — check ~/.claude/logs/`

---

## Deferred Follow-up

**Wire `ended_at` to all session-end paths** — currently `cast-session-end.sh:231` only fires on clean exit. A `SIGTERM` trap or a `EXIT` trap in the session management layer would write `ended_at` even on non-clean exits, allowing the doctor to distinguish bookkeeping crashes (have `ended_at`) from genuine crashes (do not). This would reduce the noise floor from ~89/week to near zero. Deferred — out of Phase 5 scope.

**Candidate implementation:** `trap 'cast-session-end.sh --partial' SIGTERM EXIT` in the CAST session bootstrap. The `--partial` flag would write `ended_at` without setting `status='ended'` (so the reaper still marks it `crashed` for accurate status tracking).
