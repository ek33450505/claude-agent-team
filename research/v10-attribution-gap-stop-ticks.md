# v10 I-1b — What the 54% `unknown-subagent-stop` events actually are

**Date:** 2026-08-20 (measurement only — no fixes applied)
**Question (from I-1's side finding, escalated in `plans/next-session.md`):** why does the STOP hook
resolve `unknown` 21× more often than START, and does it explain the DONE-without-response gap?

**Answer, in one line:** it is not an attribution failure. `SubagentStop` fires repeatedly *while a
subagent is still running* — roughly every 31.5 s — and those intermediate firings carry no agent
name. Real subagent completions are attributed correctly, ~1:1 with dispatches.

⚠️ **This REFUTES the escalated claim.** `plans/next-session.md` (Wave I, I-1) states the 54.4% rate
is "a live candidate explanation for the ~16% of DONE runs with no response — i.e. the C2 ship
criterion we are calling MET at 84.4% may be measuring around this bug." That link is not supported
by the evidence below and must be struck. C2 is unaffected.

---

## 1. The named/unknown split is a split between two *populations*, not two *outcomes*

Counting `~/.claude/cast/events/*-subagent-stop.json` by day, against `agent_runs` and against the
`Agent` tool-call count in `~/.claude/logs/audit.jsonl` (the PreToolUse audit, which records every
`tool_name`):

| day | stop events | of which `unknown` | named | `agent_runs` rows |
|---|---|---|---|---|
| 2026-08-18 | 175 | 116 | 59 | 62 |
| 2026-08-19 | 356 | 207 | 149 | 151 |
| 2026-08-20 | 371 | 232 | 139 | 153 |

Per session for 2026-08-20 — `Agent` tool calls vs named stop events vs `agent_runs`:

| session | `Agent` calls | named stops | `agent_runs` | `unknown` stops |
|---|---|---|---|---|
| 37e36633 | 38 | 37 | 38 | 33 |
| 395ceb16 | 27 | 30 | 31 | 98 |
| ea389643 | 19 | 19 | 19 | 5 |
| 46708bb2 | 11 | 12 | 12 | 41 |
| d87a3493 | 6 | 6 | 6 | 4 |
| 17d2cd31 | 1 | 9 | 11 | 47 |

**ESTABLISHED:** named stop events track dispatches ~1:1 in every session (the small excess over
`Agent` calls is nested dispatch — writers that spawn their own reviewer share the parent's
`session_id`). The `unknown` count tracks *nothing* — 47 of them in a session with one `Agent` call,
5 in a session with 19. If `unknown` were failed attribution of real completions, it would scale with
dispatch volume. It does not.

## 2. They arrive on a metronome

Inter-arrival gaps between consecutive `unknown` stop events within the same `session_id`, all 780
events in the retained events dir (663 gaps ≤ 600 s):

```
  31s  72     9s  17    62s  12     ← 61–62 s is the same beat with one tick missed
  32s  64    16s  12    13s  11
  33s  21    17s  11    21s   9
```

157 of 663 gaps fall in the 31–33 s band, plus 20 more at its 61–62 s harmonic. Agent completions do
not cluster on a 31.5-second period. **No launchd job has a matching interval** — across ALL of
`~/Library/LaunchAgents/*.plist`, only two declare `StartInterval` at all (`com.cast.abandon-stale-runs`
7200, `com.cast.backup` 21600) — so the emitter is inside Claude Code, not CAST or the OS scheduler.

## 3. The beat runs exactly for the duration of an in-flight subagent

Session `17d2cd31`, transcript cross-referenced against the events dir. A single `Agent` dispatch was
issued at `00:32:36Z`; its `task-notification` returned at `00:39:30Z`:

```
00:32:36Z  transcript: TOOL:Agent          ← dispatch
00:33:09Z  unknown-subagent-stop
00:33:40Z  unknown-subagent-stop           (+31s)
00:34:12Z  unknown-subagent-stop           (+32s)
   … 9 more, every 31–32 s …
00:39:24Z  unknown-subagent-stop           (+31s)
00:39:29Z  backend-writer-subagent-stop    ← the real completion, correctly attributed
00:39:30Z  transcript: task-notification   ← dispatch returns
```

Twelve `unknown` ticks bracketed by one dispatch and one correctly-named completion. **ESTABLISHED:**
the ticks are intra-run events for an agent that has not finished, and the terminal event for that
same run carries the agent name.

⚠️ **Timer vs per-turn is still INFERRED.** A ~31.5 s period is equally consistent with a fixed
heartbeat and with the mean turn duration of a working subagent. Distinguishing them needs the
raw-stdin capture I-1 already proposed; nothing in the hook chain records the payload. The
distinction does not change any conclusion below.

## 4. Why the name is absent — and why the DB fallback cannot recover it

`scripts/cast_subagent_stop.py:385-401`:

```python
raw_name = data.get("agent_type") or data.get("agent_name") or data.get("subagent_name") or ""
agent_id  = data.get("agent_id") or data.get("subagent_id") or ""
agent_name = raw_name or "unknown"
...
if agent_name == "unknown" and agent_id:
    row = conn.execute("SELECT agent FROM agent_runs WHERE agent_id = ? LIMIT 1", (agent_id,)).fetchone()
```

and the precondition guard at `:2107`:

```python
if not ctx.has_agent_identity:   # bool(raw_name or agent_id)
    return 0
```

So an `unknown` stop event is only ever written when `raw_name` was empty **and** `agent_id` was
non-empty (otherwise the guard returns before stage 1) **and** the `agent_id` lookup found no
`agent_runs` row. The ticks therefore carry an `agent_id` that CAST has never seen — not the
dispatched agent's id, which `cast-subagent-start-hook.sh:165` does store and which resolves fine for
the terminal event 139 times a day.

## 5. `"source": "SubagentStop"` in the event file proves nothing

`cast_subagent_stop.py:555` writes `"source": "SubagentStop"` as a **hardcoded string literal**, not a
value read from the payload. I-1 cited the analogous `"source":"SubagentStart"` field as confirming
which hook fired; for the start hook that conclusion happens to be right on other grounds, but the
field itself is not evidence — it is a constant. Same family as the repo's standing warning about
predicates that are exactly true and say nothing.

## 6. What this actually costs (the real defects, all measured)

1. **`cast-stats.sh --brief` miscounts by ~2.4× — but it is DEAD CODE.**
   `scripts/cast-stats.sh:19-21` counts event *files*:
   ```bash
   agents_today=$(ls "$EVENTS_DIR" | grep -c "^${TODAY}T.*subagent-stop\.json$")
   dispatches=$(ls  "$EVENTS_DIR" | grep -c "subagent-stop\.json$")
   ```
   For 2026-08-20 that reports **371 agents today** against **153** real `agent_runs` rows, and the
   comment on the line — "subagent-stop files = completed agent runs" — is false.

   ⚠️ **CORRECTION, same session.** The first version of this file called this "the statusLine."
   **It is not.** `statusLine` in `~/.claude/settings.json` runs `cast-statusline.sh`, which already
   reads `agent_runs` (`scripts/cast-statusline.sh:76-80`) and is unaffected. `cast-stats.sh --brief`
   has **zero callers** — repo-wide grep and live `~/.claude` both come up empty; it is a superseded
   statusLine implementation nobody removed. I read the branch's own comment ("output a single status
   line for statusLine setting") as evidence of its wiring, which is the *exact* failure this file
   flags in §5: a self-description is not a wiring check. Severity accordingly drops from "a number
   Ed sees daily is wrong" to "a dead branch would be wrong if revived" — plus one live doc error:
   `docs/architecture/cast-protocol-spec.md:855` describes `cast-stats.sh` as "Usage analytics from
   cast.db", which is false for this branch. The disposition question is now delete-vs-fix, not fix.
2. **All 18 hook stages run on every tick.** `main()` returns early only on the identity guard, which
   ticks pass. Stage 2 opens and scans the session transcript (guarded at 20 MB) roughly every 31 s
   per in-flight agent. This is repeated work with no record value.
3. **Events-dir pressure:** 780 of 1430 retained stop artifacts (54.5%) are ticks.
4. **POSSIBLE, not established — false protocol violations.** 68 `agent_protocol_violations` rows
   carry `agent_type='unknown'` (2 of them today, against 232 ticks). A tick has no Status line by
   construction, so it is a plausible source for some of these, but the rate does not match and the
   link is unproven. Do not cite it as cause without a per-row timestamp correlation.

## 7. Relationship to I-2 (the 19-row start-side bug) — separate, do not merge

Verified directly:

```sql
SELECT status, COUNT(*) FROM agent_runs WHERE agent='unknown' GROUP BY status;
-- abandoned 11 | failed 6 | running 2      (19 rows; ALL have empty agent_id AND empty session_id)
```

Every `agent='unknown'` row in `agent_runs` comes from the START hook and has **empty** `agent_id`.
The stop ticks always carry a non-empty `agent_id` and — because `stage0_fast_write` finds no
matching row — write **no** `agent_runs` row at all. The two populations do not intersect. I-2's
NULL-vs-`''` `session_id` mismatch is untouched by anything here and remains the right fix for the
19 rows.

## 8. Open questions for the fix unit (deliberately not decided here)

- **(a)** Suppress or keep? A tick is genuine signal that an agent is alive — `cast agents --live`
  could use it. But it must not be written to the same artifact namespace that `cast-stats.sh` counts
  as completions.
- **(b)** Where to gate: an early return in `main()` when the `agent_id` resolves to no `agent_runs`
  row would drop ticks at ~zero cost, but would also drop any genuinely orphaned terminal event.
  Narrower: gate on `stop_reason`/payload shape once raw-stdin capture tells us what distinguishes a
  tick from a completion.
- **(c)** `cast-stats.sh` should count `agent_runs`, not files, regardless of what (a) and (b) decide
  — that is a defect on its own terms.
- **(d)** ⚠️ **Any fix must be mutation-tested against a real tick**, not a synthesized payload: the
  discriminator is exactly what is not yet established (§3). A fix built from the hypothesis is the
  failure mode this repo has already paid for twice.

## 9. Re-runnable commands

```bash
# population split, per day
for d in 20260818 20260819 20260820; do
  tot=$(ls ~/.claude/cast/events/ | grep -c "^${d}T.*subagent-stop")
  unk=$(ls ~/.claude/cast/events/ | grep -c "^${d}T.*-unknown-subagent-stop")
  runs=$(sqlite3 ~/.claude/cast.db "SELECT COUNT(*) FROM agent_runs WHERE started_at LIKE '${d:0:4}-${d:4:2}-${d:6:2}%';")
  echo "$d stop_events=$tot unknown=$unk agent_runs=$runs"
done

# the statusline overstatement, live
bash ~/.claude/scripts/cast-stats.sh --brief
sqlite3 ~/.claude/cast.db "SELECT COUNT(*) FROM agent_runs WHERE started_at LIKE '$(date +%Y-%m-%d)%';"
```

⚠️ Every figure here is from the retained window (events dir oldest artifact 2026-08-16; `agent_runs`
~30 days). Re-measure before citing — do not copy a number out of this file.

---

# ADDENDUM — I-1c: the ticks IDENTIFIED, and what they were doing to the record

**Date:** 2026-08-20, same session. The capture built in `25135db` was armed
(`mkdir ~/.claude/cast/debug/stdin-capture`), one `researcher` was dispatched, and 7 raw payloads
were captured. Timer-vs-per-turn (§3's open question) is now **ESTABLISHED**, and the answer came
with a second finding that outranks the first.

## A. The discriminator is `agent_type`

Six of seven captures were ticks; one was the real completion.

| field | tick (6×) | real completion (1×) |
|---|---|---|
| `agent_type` | `""` — empty string | `"researcher"` |
| `agent_id` | a DIFFERENT ephemeral id per tick, matching no `agent_runs` row | `a56fb899387e6b9ef` — the dispatched agent's real id |
| `hook_event_name` | `SubagentStop` (genuinely, in the RAW payload — not the hardcoded field of §5) | `SubagentStop` |
| payload size | ~1.2 KB | 10.7 KB |
| `background_tasks` | lists the in-flight subagent | lists itself |
| `stop_hook_active` | `False` | `False` — NOT a discriminator |

**Why they get through:** `cast_subagent_stop.py:2107` gates on
`has_agent_identity = bool(raw_name or agent_id)`. The `or agent_id` clause is the hole — ticks carry
an `agent_id` but no name. A real completion always carries `agent_type`.

**Corrected model of the emitter:** these fire while a background subagent is in flight, carry the
*enclosing session's* last message rather than any subagent's output, and are not per-subagent-turn
events at all. The ~31.5 s beat in §2 is the cadence of the enclosing session's own turns, which is
why it looked like a timer and why it scaled with session activity rather than dispatch count.

## B. ⭐⭐ THE SPOOF CHANNEL — this is the real defect

The `last_assistant_message` on the six tick payloads read, verbatim:

```
"show me a tick payload vs a real completion"
"Grepping project-board.json readers"
"Grepping cast-stats.sh callers repo-wide"
"Confirming cast-stats.sh orphan-lint gap"
"Quoting protocol-spec.md line 855"
```

Every one of these arrived in this session as a `<subagent-report source="cast-subagent-stop"
trust="untrusted-agent-output"> … "response_excerpt": …` block — a 1:1 match, plus
`"push it and open the PR"` earlier in the same session.

**So the stop hook is relaying, as "a subagent's reported output", text that no subagent produced.**
Two of the strings this session were phrased as direct user instructions authorising an irreversible
act (`push it and open the PR`) or directing the next step (`show me a tick payload…`). Neither came
from Ed.

⚠️ **This is the mechanism behind [[reference_subagent_excerpts_can_spoof_user_approval]]** — the
~10 logged incidents of an excerpt appearing to be user approval to push, which until now had no
identified producer. It is not a model misreading; a real component is feeding
non-subagent text into a subagent-attributed channel.

**This re-prioritises I-1c.** It is not a statistics-hygiene fix. It closes a channel that has
repeatedly manufactured apparent authorisation for `git push` / PR-merge.

## C. What the fix should be (now built from an OBSERVED discriminator, per §8d)

Gate on **`agent_type` being non-empty**, not on `raw_name or agent_id`:

- a real completion always supplies `agent_type` (observed);
- ticks never do (observed, 6/6);
- the existing `agent_id → agent_runs` DB fallback stays for the genuinely-orphaned terminal event,
  but must no longer be sufficient on its own to admit an event.

⚠️ **Mutation-test against a REAL captured tick payload**, not a synthesised one — the capture
directory now contains six. This is exactly the case
[[reference_probe_fixture_built_from_hypothesis]] warns about: a fixture built from the hypothesis
would have had `agent_type` absent for the wrong reason.

⚠️ **Verify the fix by ABSENCE of the old path** ([[reference_probe_can_discriminate_wrong_axis]]):
after the gate, a dispatched agent must still produce exactly ONE named stop event, AND zero
`unknown` ones, AND no `<subagent-report>` carrying a message the subagent never wrote.

## D. Re-runnable

```bash
mkdir -p ~/.claude/cast/debug/stdin-capture     # arm
# dispatch any agent, wait for it to finish
python3 - <<'PY'
import json,glob,os
for f in sorted(glob.glob(os.path.expanduser('~/.claude/cast/debug/stdin-capture/*.json'))):
    d=json.load(open(f))
    print(f"{os.path.basename(f)}  agent_type={d.get('agent_type')!r}  "
          f"msg={str(d.get('last_assistant_message'))[:60]!r}")
PY
rm -rf ~/.claude/cast/debug/stdin-capture       # disarm (payloads contain full agent output)
```
