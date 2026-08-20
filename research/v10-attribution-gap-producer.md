# v10 Attribution Gap — Producer of `agent='unknown'` Rows

**Date:** 2026-08-20 (measurement only — no fixes applied)
**Question:** Which producer writes `agent_runs` rows with `agent='unknown'`? Why does the payload lack the agent name? Is the rate improving or worsening around PR #365 (merged 2026-08-18)?

**Window span (ESTABLISHED):**
```sql
SELECT MIN(started_at), MAX(started_at), COUNT(*) FROM agent_runs;
-- 2026-07-21T12:25:43Z | 2026-08-20T18:41:54Z | 3264 rows (measured 2026-08-20 ~18:45Z)
```
This is a ~30-day retained window, not the full history — re-run before citing any figure below; the window prunes.

## Q1 — Which producer writes these rows?

**ESTABLISHED:** The producer is `~/.claude/scripts/cast-subagent-start-hook.sh`, the `SubagentStart` hook (`* | bash ~/.claude/scripts/cast-subagent-start-hook.sh`, confirmed in `~/.claude/settings.json`). Evidence chain:

1. `agent_runs` rows: 19 total with `agent='unknown'` in the retained window, ALL with empty `session_id` and empty `agent_id`:
   ```sql
   SELECT id, status, started_at, session_id, agent_id FROM agent_runs WHERE agent='unknown' ORDER BY started_at;
   -- running=11 (all 2026-08-20), failed=6 (5×2026-08-04, 1×2026-08-16), abandoned=2 (2026-08-16)
   ```
2. A matching event artifact exists for 16 of the 19 rows at `~/.claude/cast/events/<TS>-unknown-subagent-start.json`, e.g. `20260820T141352Z-unknown-subagent-start.json` (started_at `2026-08-20T14:13:52Z` — exact match to row id 12485). Content:
   ```json
   {"event_id":"unknown-subagent-start-2026-08-20T14:13:52Z","timestamp":"2026-08-20T14:13:52Z",
    "event_type":"task_claimed","agent":"unknown","session_id":"","source":"SubagentStart"}
   ```
   `"source":"SubagentStart"` in the event payload directly confirms the hook that fired. The 3 unmatched rows (2026-08-04) predate the events directory's own retention (oldest surviving event file is 2026-08-16 — shorter retention than `agent_runs`), so absence there is a retention gap, not counter-evidence.
3. Re-runnable command: `ls ~/.claude/cast/events/ | grep -c "unknown-subagent-start"` → 16 of 611 total `*-subagent-start.json` files (2.6%).

**Side finding, INFERRED, out of this task's scope but flagged:** `*-subagent-stop.json` event files are `unknown` at a far higher rate — 757 of 1398 (54%) via `ls ~/.claude/cast/events/ | grep -c "unknown-subagent-stop"`. This is a structurally different hook (`cast-subagent-stop-hook.sh` / `cast_subagent_stop.py`) with a much worse attribution rate at the event-log layer. Whether this also produces bad `agent_runs` rows was not checked here — separate investigation warranted, do not conflate with the 19-row finding above.

**Terminal status mechanism (ESTABLISHED, explains "never DONE"):** These rows structurally cannot reach `DONE`. `SubagentStop` can only update a row it can match by `session_id`/`agent_id`, and these rows have neither. Two independent stale-row reapers age them out instead:
```
scripts/cast-maintenance.sh:54:  UPDATE agent_runs SET status='failed', ... WHERE status='running' AND datetime(started_at) < datetime('now','-2 hours');
scripts/cast-session-end.sh:268: UPDATE agent_runs SET status='failed', ... WHERE status='running' AND started_at < datetime('now','-2 hours');
scripts/cast-abandon-stale-runs.py: SET status='abandoned', abandoned_at=... (CAST_ABANDON_STALE_HOURS, default 2h)
```
This is why `running:11 / failed:6 / abandoned:2 / DONE:0` is the expected shape, not a coincidence — it is two reapers racing on the same 2h-stale condition, never a completion event.

## Q2 — Why does the payload lack the agent name?

**Distinguishing (a) parse failure vs (b) well-formed-but-empty payload vs (c) something else:**

**INFERRED, moderate-to-strong confidence: (a), driven by a cross-hook temporal correlation, not a direct stdin capture.** Neither `cast-subagent-start-hook.sh` nor its embedded Python logs the raw stdin on any path (success or the `2>/dev/null` failure branches at lines 51 and 82-93), so the literal bytes that hit the hook were not recoverable this session. What IS recoverable: a second, independent hook — `cast-audit-hook.sh --mode post` → `cast-audit.py`, wired on `PostToolUse` for the `Agent|Task` matcher (different hook event, same underlying tool dispatch) — logs an explicit, catchable error:
```python
# scripts/cast-audit.py:538
except Exception:
    _log_error("invalid JSON on stdin")   # raw.strip() was non-empty but json.loads() raised
```
This message fired within 1-2 seconds of 9 of the 11 `running`-unknown rows and both correlated `abandoned` rows:
```
[2026-08-20T14:13:50Z] ERROR cast-audit.py: invalid JSON on stdin   →  row 12485 started_at 14:13:52Z
[2026-08-20T14:14:19Z] / [14:14:22Z] / [14:14:23Z]                  →  rows 12486 (14:14:21Z), 12487 (14:14:25Z)
[2026-08-20T14:30:54Z] → row 12493 (14:30:56Z)   [2026-08-20T14:31:25Z] → row 12495 (14:31:27Z)
[2026-08-20T14:32:48Z] → row 12497 (14:32:50Z)   [2026-08-20T14:36:14Z] → row 12499 (14:36:16Z)
[2026-08-20T14:38:24Z] → row 12500 (14:38:26Z)   [2026-08-20T17:07:55Z] → row 12523 (17:07:57Z)
[2026-08-20T17:13:34Z] → row 12525 (17:13:36Z)
[2026-08-16T03:41:27Z] → row 11899 (03:41:29Z, failed)   [2026-08-16T16:16:41Z] → row 11903 (16:16:43Z, abandoned)
[2026-08-16T18:35:41Z] → row 11944 (18:35:43Z, abandoned)
```
Re-run: `grep -i "invalid JSON on stdin" ~/.claude/logs/hook-errors.log`. Two *independent* Python processes, on two *different* hook events for the same tool dispatch, both fail to parse JSON within the same 1-2 second window. `cast-audit.py`'s error is unambiguous about the mechanism (a `json.loads()` exception on non-empty stdin) — that is direct evidence for (a) in the sibling hook, and strong circumstantial evidence that `cast-subagent-start-hook.sh`'s stdin was similarly malformed at the same moment, not merely missing the three name keys. This argues against (b): a well-formed payload missing `agent_type`/`agent_name`/`subagent_name` would not also break an unrelated JSON parser reading a differently-shaped payload for the same event.

**Not established:** the actual byte-level corruption (truncated write, concatenated JSON objects, a race in how Claude Code streams hook stdin under concurrent dispatch). All 19 rows occur while 2+ Claude Code sessions were dispatching subagents concurrently (confirmed via distinct `session_id`s active in the same minute — e.g. `37e36633…` and `46708bb2…` both active 14:00-14:56Z on 2026-08-20; `ea389643…` and `395ceb16…` both active 17:04-17:19Z). Concurrency-under-load as the trigger for malformed stdin delivery is **INFERRED, not confirmed** — no stdin capture exists to prove it.

**Caveat on log coverage:** `~/.claude/logs/hook-errors.log` begins 2026-08-13T13:26:22Z (`head -1`), so the 5 `failed` rows from 2026-08-04 predate the log and cannot be checked either way — treat Q2's finding as established only for the 14 rows from 2026-08-16 onward, not the full 19.

## Q3 — Is this getting better or worse?

**ESTABLISHED counts (re-run before citing):**
```sql
SELECT strftime('%Y-W%W', started_at) AS wk, COUNT(*) FROM agent_runs WHERE agent='unknown' GROUP BY wk ORDER BY wk;
-- 2026-W31: 5   2026-W32: 3   2026-W33: 11  (W33 = 2026-08-17 .. in progress, today is 08-20)

SELECT strftime('%Y-W%W', started_at) AS wk, COUNT(*) FROM agent_runs GROUP BY wk ORDER BY wk;
-- W29:302  W30:949  W31:907  W32:520  W33:587  (denominators, all-status)
```
Rate: W31 ≈ 0.55% (5/907), W32 ≈ 0.58% (3/520), W33 ≈ 1.87% (11/587) so far.

**PR #365** (`55b1106`, merged 2026-08-18) landed inside W33. Splitting W33 at the merge boundary:
```sql
SELECT CASE WHEN started_at < '2026-08-18' THEN 'pre-365' ELSE 'post-365' END, COUNT(*)
FROM agent_runs WHERE agent='unknown' AND strftime('%Y-W%W',started_at)='2026-W33' GROUP BY 1;
-- pre-365: 0   post-365: 11   (all 11 unknown rows in W33 are AFTER the merge)
```
Rate post-365 within W33: 11/361 ≈ 3.0% vs pre-365 0/226 ≈ 0%.

**INFERRED, low confidence given N=19 total and a partial week:** the raw rate looks like it went UP after #365, not down — but `git show --stat 55b1106` shows the PR touched the **reaper/attribution-repair** scripts (`cast-abandon-stale-runs.py` +306, `cast_subagent_stop.py` +80, `cast-maintenance.sh`, `cast-session-end.sh`) and NOT the producer (`cast-subagent-start-hook.sh`, untouched — 0 hits for `git show --stat 55b1106 | grep -i "subagent-start-hook"`) or `cast-audit.py` (also untouched). So #365 could not plausibly have *caused* more malformed-stdin events; the pre/post split most likely reflects W33 being a short, unrepresentative sample (3 days pre-merge vs partial week post-merge, both low-N) rather than a real regression from #365. **This needs a full subsequent week (W34) before drawing a causal conclusion either way.**

## Answered vs Open

| Question | Verdict | Basis |
|---|---|---|
| Producer | `cast-subagent-start-hook.sh` (SubagentStart) | ESTABLISHED — event artifact `"source":"SubagentStart"` matches row timestamps exactly |
| Mechanism | (a) genuine JSON parse failure on stdin, not (b) well-formed-missing-fields | INFERRED — cross-hook `cast-audit.py` "invalid JSON on stdin" correlates within 1-2s for 14/19 rows; no direct stdin capture exists |
| Trend vs #365 | Inconclusive; W33 rate rose but #365 didn't touch the producer | INFERRED, low confidence — N too small, week incomplete |
| "Never DONE" | Structural, not incidental | ESTABLISHED — rows lack session_id/agent_id so SubagentStop cannot match them; two independent 2h-stale reapers (`cast-maintenance.sh`, `cast-session-end.sh`, `cast-abandon-stale-runs.py`) age them to failed/abandoned |

## Open items for a future session (not investigated here — out of scope for a measurement-only pass)
- The 54% `unknown` rate on `*-subagent-stop.json` event files (757/1398) — separate, larger problem, different hook, not confirmed to touch `agent_runs` rows.
- 3 `unknown-subagent-start.json` event files exist for 2026-08-16 19:10-19:15Z with no corresponding `agent='unknown'` row currently in `agent_runs` — unexplained; possibly reconciled by a later process, not confirmed.
- No raw-stdin capture exists anywhere in the hook chain; adding one (behind a debug flag) would let a future session confirm/refute the (a) vs (b) split directly instead of by correlation.

## Full re-run command set
```bash
sqlite3 ~/.claude/cast.db "SELECT MIN(started_at), MAX(started_at), COUNT(*) FROM agent_runs;"
sqlite3 ~/.claude/cast.db "SELECT id, status, started_at, session_id, agent_id FROM agent_runs WHERE agent='unknown' ORDER BY started_at;"
sqlite3 ~/.claude/cast.db "SELECT strftime('%Y-W%W', started_at) wk, COUNT(*) FROM agent_runs WHERE agent='unknown' GROUP BY wk ORDER BY wk;"
sqlite3 ~/.claude/cast.db "SELECT strftime('%Y-W%W', started_at) wk, COUNT(*) FROM agent_runs GROUP BY wk ORDER BY wk;"
grep -i "invalid JSON on stdin" ~/.claude/logs/hook-errors.log
ls ~/.claude/cast/events/ | grep -c "unknown-subagent-start"
ls ~/.claude/cast/events/ | grep -c "unknown-subagent-stop"
git show --stat 55b1106
```
