---
description: CAST ci-watch command
---

# /ci-watch — autonomous CI-watch-and-merge loop

Opt-in, self-paced loop: watch the current branch's PR and auto-merge once **all CI checks are green AND every review thread is resolved**. Session-scoped — it dies when the terminal closes (babysitting, not unattended infra).

## Guardrails (read before running)
- **Opt-in only.** Never auto-start on every push.
- **One loop per PR** — `cast-ci-watch.sh start` refuses a second concurrent loop for the same PR.
- **90-minute hard cap** — ends gracefully on merge, failure, or timeout; never lean on the wake-up auto-expiry.
- **Budget ceiling already armed** (`cast budget set` $25/day). If `[CAST-BUDGET-HARD-LIMIT]` fires, STOP.
- **Idempotent** — `gh pr merge` short-circuits an already-merged PR.

## Procedure (run in the main session)
1. Resolve the PR for the current branch: `gh pr view --json number --jq .number`. No PR → report and stop.
2. `bash ~/.claude/scripts/cast-ci-watch.sh start <pr>`. If it reports a loop already running for this PR, stop (don't double-run).
3. **Poll:** `bash ~/.claude/scripts/cast-ci-watch.sh status <pr>` → read JSON `.verdict`:
   - **MERGE** → `gh pr merge <pr> --squash --delete-branch` → `bash ~/.claude/scripts/cast-ci-watch.sh stop <pr>` → report the merge → **END (do not ScheduleWakeup).**
   - **FAIL** → report which check(s) failed → `bash ~/.claude/scripts/cast-ci-watch.sh stop <pr>` → **END.** (Do not loop on red. If the user asked, dispatch `debugger` here.)
   - **EXPIRED** → report "90-min cap reached, PR still not mergeable" → `stop` → **END.**
   - **ERROR** → the status pipeline itself failed (gh fetch / GraphQL / parse — see `.error` reason code and `~/.claude/logs/hook-errors.log`). Report it → `stop` → **END.** Never keep polling on ERROR — a broken pipeline wearing WAIT is how green PRs idle to EXPIRED.
   - **WAIT** → schedule the next poll and re-enter `/ci-watch`:
     - checks actively running → `ScheduleWakeup(delaySeconds: 180, prompt: "/ci-watch")` (cache-warm).
     - checks queued / idle / waiting on review → `ScheduleWakeup(delaySeconds: 1800, prompt: "/ci-watch")`.
4. The loop ENDS by simply not rescheduling after MERGE / FAIL / EXPIRED.

## Honest limit
Only runs while this session is open. For unattended cross-repo stale-PR nudging, that's a separate scheduled routine — not this.
