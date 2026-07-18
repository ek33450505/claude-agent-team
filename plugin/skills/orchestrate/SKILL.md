---
name: orchestrate
description: Execute a CAST plan by reading the Agent Dispatch Manifest and dispatching agents in dependency order — parallel batches simultaneously, sequential batches one at a time. Pass a plan file path, 'next' for the most recent plan, or 'resume' to continue from a checkpoint.
user-invocable: true
allowed-tools: [Read, Glob, Bash, Agent, Write, TaskCreate, TaskUpdate, TaskList]
---

# Orchestrate

This is the `/orchestrate` skill. It reads a plan's Agent Dispatch Manifest and executes the agent queue directly from the main session.

> Native Dynamic Workflows (Phase 10) are preferred for new non-critical dispatches. This skill is the stable LEGACY fallback.

## Arguments

$ARGUMENTS

## Step 1 — Resolve the plan path

**If a file path was provided as an argument:** use it directly.

**If argument is `next` or no argument:** find the most recent plan file:
```bash
ls -t ~/.claude/plans/*.md | head -1
```

**If argument is `resume`:** find any checkpoint log in `~/.claude/cast/orchestrator-checkpoint-*.log`. Read the most recent one to extract the plan path and last completed batch.

If no plan file can be found, output: "No plan file found in ~/.claude/plans/. Run /plan first to write one."

## Step 2 — Read the Manifest

Read the plan file. Find the `## Agent Dispatch Manifest` section and parse the `json dispatch` block.

If no manifest exists: report "No Agent Dispatch Manifest found in [plan file]." and stop.

Check for a checkpoint:
```bash
PLAN_HASH=$(echo -n "$PLAN_FILE_PATH" | shasum -a 256 | cut -c1-8)
CHECKPOINT_FILE=~/.claude/cast/orchestrator-checkpoint-${PLAN_HASH}.log
```
If the checkpoint exists, read the last completed batch ID and skip batches with id <= that number.

### Log Dispatch

```bash
python3 ~/.claude/scripts/orchestrate-dispatch.py log-dispatch \
  --plan "$PLAN_FILE_PATH" --session-id "${CAST_SESSION_ID:-${CLAUDE_SESSION_ID:-}}" 2>/dev/null || true
```

Create one TaskCreate entry per batch (subject = "Batch N: [description]").

## Step 2.5 — Branch Pre-Flight

Read `target_branch` from the manifest JSON (parsed in Step 2), then:
```bash
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
TODAY=$(date +%Y%m%d); CUTOVER=20260603
```

**Case 1** — `target_branch` absent AND today < CUTOVER: warn `[CAST-ORCHESTRATE] DEPRECATION WARNING: omits target_branch. Plans without target_branch will fail from 2026-06-03.` Log and proceed.
**Case 2** — `target_branch` absent AND today ≥ CUTOVER: BLOCK. `target_branch` is required in the manifest (enforced since 2026-06-03). Stop.
**Case 3** — `target_branch` matches current branch: log `[CAST-ORCHESTRATE] Branch check passed: $CURRENT_BRANCH` and continue.
**Case 4** — `target_branch` present but branch mismatch: print current vs target, stop and wait for explicit "y"/"yes" before proceeding to Step 3. Prevents C3-on-C2-branch errors.

## Step 3 — Present the Queue

Print the batch list as an informational summary. Do not wait for input. Proceed immediately.

```
Agent Dispatch Queue — [Plan Name]
═══════════════════════════════════════════════
  Batch 1 (sequential): agent-name
  Batch 2 (parallel)  : agent-a, agent-b
═══════════════════════════════════════════════
Total: N agents across M batches
Executing in 10 seconds...
```

Run the interrupt window:
```bash
for i in $(seq 10 -1 1); do printf "\r  Starting in %2ds..." $i; sleep 1; done; echo
```
If you receive a message containing "abort" before Batch 1 dispatches, print "Aborted." and stop.

## Step 4 — Execute Each Batch

At the start of this step, before dispatching any batch, set:
```bash
export CAST_ORCHESTRATE_ACTIVE=1
```
This suppresses CAST-CHAIN and CAST-REVIEW hook noise for the duration of the orchestrate session.

Before each batch:
- Mark its task `in_progress`
- Check turn budget: if fewer than 5 turns remain, write checkpoint and stop: "TURN LIMIT APPROACHING: paused at Batch N. Resume with `/orchestrate resume`."
- For parallel batches: check `owns_files` — if two agents claim the same file, report FILE OWNERSHIP CONFLICT and stop.
- For parallel batches: check co-scheduling — if the batch contains `test-runner` AND any of {`code-reviewer`, `security`, `frontend-qa`}, report CO-SCHEDULING CONFLICT and either stop or auto-serialize `test-runner` into its own sequential batch before dispatching the rest. (test-runner's suite-timeout/kill path can reap co-scheduled sibling review processes — observed 2026-06-14.)

**Prompt construction for Agent tool calls:**
Before passing the `prompt` field from the ADM to the Agent tool, prepend a context preamble. Use the **full preamble** for implementation agents and the **minimal preamble** for lightweight agents:

**Full preamble** — use for: backend-writer, frontend-writer, debugger, security, researcher, planner, test-writer, bash-specialist
```
[CAST SHARED CONTEXT]
Project: claude-agent-team
Repo: $CAST_REPO_DIR (or infer from git root)
Stack: Bash + Python + SQLite | BATS tests in tests/
DB access: always use scripts/cast_db.py (db_write, db_query, db_execute)
Conventions: YAGNI, DRY, exit 0 on all async hooks, exit 2 to block PreToolUse
Working dir: $CAST_REPO_DIR (or infer from git root)
[END CAST SHARED CONTEXT]
```

**Minimal preamble** — use for: commit, push, test-runner, code-reviewer, frontend-qa, merge, docs, devops, morning-briefing
```
[CAST CONTEXT]
Repo: $CAST_REPO_DIR (or infer from git root)
[END CAST CONTEXT]
```

Then wrap with:
```
[AGENT TASK]
{prompt from ADM goes here}
[END AGENT TASK]
```

Apply the appropriate preamble tier to ALL agent dispatches — both parallel and sequential batches.

**Parallel batches** (`"parallel": true`): dispatch all agents simultaneously in one response using the Agent tool.

**Sequential batches** (`"parallel": false`): dispatch the single agent, wait for response.

**After each agent responds:**
1. If response length < 50 chars, retry once: "Your response was truncated. Please provide your complete Status block."
2. **Contract validation** — valid Status values: `DONE`, `DONE_WITH_CONCERNS`, `BLOCKED`, `NEEDS_CONTEXT`. If missing AND length > 50 chars, retry once: "Your response is missing a Status block. End with Status: DONE (or DONE_WITH_CONCERNS / BLOCKED / NEEDS_CONTEXT)." On retry failure, attempt status file fallback (below).

**Status file fallback (Phase 4.9):** Before declaring BLOCKED, run:
```bash
FILE_STATUS=$(python3 ~/.claude/scripts/orchestrate-dispatch.py recent-status --agent "$AGENT_NAME" --max-age 300 2>/dev/null)
```
If non-empty, use as recovered Status and log `contract_passed=-1` to `quality_gates`. Only treat as BLOCKED if both retry AND file fallback fail.

**Test-runner file truth (Phase 4.11):** For `test-runner`, file status wins over prose — run:
```bash
FILE_STATUS=$(python3 ~/.claude/scripts/orchestrate-dispatch.py recent-status --agent test-runner --max-age 300 2>/dev/null)
```
If file differs from prose, trust file and log `[CAST] test-runner prose said X but file says Y — trusting file.` This rule applies BEFORE Phase 4.9.

3. Log validation result to cast.db:
```bash
python3 ~/.claude/scripts/orchestrate-dispatch.py log-quality-gate \
  --batch-id "$BATCH_ID" --agent "$AGENT_NAME" \
  --status "$STATUS_LINE" --contract-passed "$CONTRACT_PASSED" \
  --retry-count "$RETRY_COUNT" 2>/dev/null || true
```
(`$CONTRACT_PASSED` = 1 if valid Status found first try, 0 otherwise; `$RETRY_COUNT` = 0 or 1; `$STATUS_LINE` = extracted Status line or "MISSING")

4. Route based on Status:
   - `Status: DONE` → mark task completed, write checkpoint, continue
   - `Status: DONE_WITH_CONCERNS` → log concern text, mark completed, continue
   - `Status: BLOCKED` or no Status after retry → write checkpoint and stop: "Batch N blocked. Human intervention required. Blocker: [reason]"
   - `Status: NEEDS_CONTEXT` → stop and request clarification before continuing

5. **File presence check** — after DONE/DONE_WITH_CONCERNS, run `git status --short` and `git diff --stat HEAD | tail -20`. Read 2-3 files the agent claimed to modify. If no changes but edits claimed, retry once or escalate — do NOT silently continue.

After each batch: mark task `completed`, print `[BATCH N COMPLETE]`, then:
```bash
mkdir -p ~/.claude/cast && echo "[BATCH $BATCH_ID COMPLETE] $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$CHECKPOINT_FILE"
source ~/.claude/scripts/cast-events.sh && cast_emit_event 'task_completed' 'orchestrate-skill' "batch-$BATCH_ID" '' '<summary>' '<STATUS>'
```

After all batches or early exit: `unset CAST_ORCHESTRATE_ACTIVE`.

## Step 5 — Summarize

Print a ≤200-word summary (what each batch did, any concerns). Then:
```bash
rm -f "$CHECKPOINT_FILE"
source ~/.claude/scripts/cast-events.sh
cast_emit_event 'task_completed' 'orchestrate-skill' 'session' '' 'All batches complete' 'DONE'
```
> When `VerifyPlanExecutionTool` becomes available, call it before the terminal event and log verdict to `quality_gates`. See `docs/native-tools-reference.md`.

## Mandatory Chain Entries

The following agents automatically dispatch their successor agents when status = DONE:

- **backend-writer** → code-reviewer
- **frontend-writer** → code-reviewer
- **bash-specialist** → code-reviewer
- **debugger** → test-runner
- **security** → code-reviewer

These fire automatically after each upstream agent completes and should not be re-dispatched manually in the plan.

## Output Compression Rules
- Summarize each agent's response in **under 100 words**. Never reproduce content from the agent's spawn prompt.
- Never paste full tool output, file contents, or raw WebFetch results into your context.
- If your accumulated context exceeds ~30,000 tokens (roughly 15+ agent dispatches), perform inline compaction: discard completed batch details, keep only the status summary per batch.
- When passing context to the next batch, include only: (1) the plan's remaining batches, (2) a 1-sentence summary per completed batch, (3) any blocking issues.

## Commit Pre-Stage Protocol (mandatory)

Before dispatching any commit agent:
1. The ORCHESTRATOR runs `git add <exact-files-for-this-commit>` — not the commit agent. The commit agent CANNOT `git add` (HARD RULE — its task is compose-and-commit only).
2. The dispatch prompt MUST state: "Staged files: [list]."
3. Multi-commit batches: stage → dispatch commit → SendMessage-resume for next commit → stage → dispatch. Never batch multiple logical units into one commit dispatch without staging each set first.

Blocker class: commit agent BLOCKED on "nothing to commit" = orchestrator forgot to stage.

> **Agent Teams (experimental):** When `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, parallel batches may use team-lead mode. See `docs/native-tools-reference.md`. Falls back to hub-and-spoke when unavailable.

## Truncation Fallback for Gate Agents

**`[CAST-TRUNCATED]`** fires on REAL output truncation only (model output cut mid-stream). MISSING_FORMALITY (complete-looking response, absent Status block) does NOT fire `[CAST-TRUNCATED]` — it logs an `agent_protocol_violations` row and triggers the existing Status-retry path (no banner).

**SendMessage-resume:** A resume grants a fresh turn budget. Scope dispatches to fit caps rather than relying on resumes. When resuming a capped agent, state exactly what work remains.

If `[CAST-TRUNCATED]` fires on a gate agent (test-runner, code-reviewer, security): do NOT auto-retry. Use inline fallback — test-runner: `bash tests/run.sh --tap 2>&1 | tail -20`; code-reviewer: apply checklist manually; security: grep for anti-patterns. Log as `Status: DONE_WITH_CONCERNS` and cast.db entry `agent_name='<role>-INLINE-FALLBACK'` with `contract_passed=1` (0 if issues found). If inline fallback cannot complete: BLOCK and stop.

## Rules

- Never skip a batch unless the user explicitly says to
- Maximum 4 agents per parallel batch
- Output discipline: summarize each agent in 3 sentences max. Never paste full agent output verbatim.
- If blocked after one retry: write checkpoint, stop, tell user how to resume with `/orchestrate resume`
