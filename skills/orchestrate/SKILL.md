---
name: orchestrate
description: Execute a CAST plan by reading the Agent Dispatch Manifest and dispatching agents in dependency order — parallel batches simultaneously, sequential batches one at a time. Pass a plan file path, 'next' for the most recent plan, or 'resume' to continue from a checkpoint.
user-invocable: true
allowed-tools: [Read, Glob, Bash, Agent, Write, TaskCreate, TaskUpdate, TaskList]
---

# Orchestrate

This is the `/orchestrate` skill. It reads a plan's Agent Dispatch Manifest and executes the agent queue directly from the main session.

## Native Alternative (Preferred Path)

Native Dynamic Workflows (the Workflow tool — Claude authors a JS orchestration script) are the platform-native successor to this skill's Agent Dispatch Manifest pattern. Status: **available & verified 2026-06-03** — used in production for a 7-agent fan-out this session. This `/orchestrate` + ADM path is now **LEGACY** — retained as the stable fallback until a piloted migration validates native Workflows for CAST's critical dispatch paths. New non-critical multi-agent dispatches SHOULD prefer native Dynamic Workflows over this skill. Reference: `~/.claude/research/2026-06-03-anthropic-devs-claude-code-convergence.md` (Phase 10).

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

## Step 2 — Read the Manifest [LEGACY — Phase 10 retirement target]

Read the plan file. Find the `## Agent Dispatch Manifest` section and parse the `json dispatch` block.

If no manifest exists: report "No Agent Dispatch Manifest found in [plan file]." and stop.

Check for a checkpoint:
```bash
PLAN_HASH=$(echo -n "$PLAN_FILE_PATH" | shasum -a 256 | cut -c1-8)
CHECKPOINT_FILE=~/.claude/cast/orchestrator-checkpoint-${PLAN_HASH}.log
```
If the checkpoint exists, read the last completed batch ID and skip batches with id <= that number.

### Dispatch Backend Check

Read `dispatch_backend` from `~/.claude/config/cast-cli.json`:
```bash
DISPATCH_BACKEND=$(python3 -c "import json,os; d=json.load(open(os.path.expanduser('~/.claude/config/cast-cli.json'))); print(d.get('dispatch_backend', 'cast'))" 2>/dev/null || echo 'cast')
```
Log the backend to cast.db **and** write the active plan_sessions binding (cast-desktop's `plans.ts` uses this to resolve session_id → active plan) — kept in a single `python3 -c` invocation so the LLM cannot run one write and skip the other:
```bash
python3 -c "
import sys; sys.path.insert(0, '$HOME/.claude/scripts')
from cast_db import db_write, db_execute
import datetime, os
SESSION_ID = os.environ.get('CAST_SESSION_ID') or os.environ.get('CLAUDE_SESSION_ID') or 'unknown'
NOW = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
db_execute('''
    CREATE TABLE IF NOT EXISTS dispatch_decisions (
        id TEXT PRIMARY KEY,
        session_id TEXT,
        timestamp TEXT,
        dispatch_backend TEXT,
        plan_file TEXT
    )
''')
db_write('dispatch_decisions', {
    'id': os.urandom(8).hex(),
    'session_id': SESSION_ID,
    'timestamp': NOW,
    'dispatch_backend': '$DISPATCH_BACKEND',
    'plan_file': '$PLAN_FILE_PATH'
})
try:
    db_execute('''
        CREATE TABLE IF NOT EXISTS plan_sessions (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            plan_file  TEXT NOT NULL,
            started_at TEXT NOT NULL
        )
    ''')
    db_write('plan_sessions', {
        'session_id': SESSION_ID,
        'plan_file': '$PLAN_FILE_PATH',
        'started_at': NOW,
    })
except Exception:
    pass
" 2>/dev/null || true
```
If `DISPATCH_BACKEND` is `"coordinator"` or `"auto"`, print a notice: `[CAST] dispatch_backend=$DISPATCH_BACKEND — COORDINATOR_MODE not yet supported; falling back to cast dispatch.` and continue with standard dispatch. This stub is intentional — coordinator dispatch logic will be added when COORDINATOR_MODE ships publicly.

Create one TaskCreate entry per batch (subject = "Batch N: [description]").

## Step 2.5 — Branch Pre-Flight

Read `target_branch` from the manifest JSON (the `dispatch` block parsed in Step 2). Then apply the following logic:

```bash
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
TODAY=$(date +%Y%m%d)
CUTOVER=20260603
```

**Case 1 — `target_branch` is absent AND today < 2026-06-03 (`$TODAY -lt $CUTOVER`):**
```
[CAST-ORCHESTRATE] DEPRECATION WARNING: This plan omits target_branch.
Plans without target_branch will fail to orchestrate from 2026-06-03.
Add target_branch to the manifest. Continuing with no branch check.
```
Log the warning and proceed.

**Case 2 — `target_branch` is absent AND today >= 2026-06-03 (`$TODAY -ge $CUTOVER`):**
```
BLOCKED: target_branch is required in the manifest (enforced since 2026-06-03).
Add "target_branch": "<branch-name>" to the manifest JSON and re-run.
```
Stop. Do not proceed to Step 3.

**Case 3 — `target_branch` is present AND current branch matches:**
Log `[CAST-ORCHESTRATE] Branch check passed: $CURRENT_BRANCH` and continue.

**Case 4 — `target_branch` is present AND current branch does NOT match:**
```
[CAST-ORCHESTRATE] Branch mismatch detected.
  Current branch : <CURRENT_BRANCH>
  Plan targets   : <target_branch>
Switch to the target branch before continuing? [y/N]
```
Stop and wait. Do not proceed to Step 3 unless the user explicitly confirms (replies "y" or "yes"). This prevents the C3-on-C2-branch class of errors documented in the 2026-04-16 insights report.

Inline shell reference for the cutover check (for runtime implementation):
```bash
if [[ "$(date +%Y%m%d)" -ge "20260603" ]]; then
  echo "BLOCKED: target_branch is required in the manifest (enforced since 2026-06-03)."
  # stop
else
  echo "[CAST-ORCHESTRATE] DEPRECATION WARNING: This plan omits target_branch. Plans without target_branch will fail to orchestrate from 2026-06-03. Add target_branch to the manifest. Continuing with no branch check."
  # proceed
fi
```

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
This suppresses CAST-CHAIN and CAST-REVIEW hook noise for the duration of the orchestrate session. All child processes and hooks will see this variable.

Before each batch:
- Mark its task `in_progress`
- Check turn budget: if fewer than 5 turns remain, write checkpoint and stop with: "TURN LIMIT APPROACHING: paused at Batch N. Resume with `/orchestrate resume`."
- For parallel batches: check `owns_files` across agents — if two agents claim the same file, report FILE OWNERSHIP CONFLICT and stop.

**Prompt construction for Agent tool calls:**
Before passing the `prompt` field from the ADM to the Agent tool, prepend a context preamble. Use the **full preamble** for implementation agents and the **minimal preamble** for lightweight agents:

**Full preamble** — use for: code-writer, debugger, security, researcher, planner, test-writer, bash-specialist
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

Apply the appropriate preamble tier to ALL agent dispatches — both parallel and sequential batches. The `{prompt from ADM goes here}` placeholder means: substitute the actual prompt string from the ADM agent entry.

**Parallel batches** (`"parallel": true`): dispatch all agents simultaneously in one response using the Agent tool.

**Sequential batches** (`"parallel": false`): dispatch the single agent, wait for response.

**After each agent responds:**
1. Check response length. If < 50 chars, retry once with: "Your response was truncated. Please provide your complete Status block."

2. **Contract validation** — check for a valid Status line:
   - Valid values: `Status: DONE`, `Status: DONE_WITH_CONCERNS`, `Status: BLOCKED`, `Status: NEEDS_CONTEXT`
   - If no valid Status line is found AND response length > 50 chars, retry once with: "Your response is missing a Status block. End your response with Status: DONE (or DONE_WITH_CONCERNS / BLOCKED / NEEDS_CONTEXT)."
   - On retry, if still missing: attempt status file fallback before declaring BLOCKED (see below).
   - **Status file fallback (truncation resilience — Phase 4.9):** Before declaring BLOCKED, check for a recent status file at `~/.claude/agent-status/<agent>-*.json`. Find the most recent matching file with `mtime` within the last 300 seconds:
     ```bash
     AGENT_NAME="<agent name or subagent_type from the ADM entry>"
     STATUS_FILE=$(python3 -c "
import os, glob, sys
files = glob.glob(os.path.expanduser('~/.claude/agent-status/'+sys.argv[1]+'-*.json'))
if files:
    files.sort(key=lambda f: os.path.getmtime(f), reverse=True)
    print(files[0])
" "$AGENT_NAME" 2>/dev/null)
     if [ -n "$STATUS_FILE" ] && [ -f "$STATUS_FILE" ]; then
       FILE_MTIME=$(python3 -c "import os,sys; print(int(os.path.getmtime(sys.argv[1])))" "$STATUS_FILE" 2>/dev/null || echo 0)
       NOW=$(date +%s)
       AGE=$((NOW - FILE_MTIME))
       if [ "$AGE" -le 300 ]; then
         FILE_STATUS=$(python3 -c "
     import json, sys
     try:
         d = json.load(open('$STATUS_FILE'))
         print(d.get('status', ''))
     except Exception:
         pass
     " 2>/dev/null)
         if [ -n "$FILE_STATUS" ]; then
           # Use file-status as authoritative; skip the BLOCKED path
           STATUS_LINE="Status: $FILE_STATUS (recovered from status file)"
           # Proceed to step 4 routing with the recovered status
         fi
       fi
     fi
     ```
   - If the status file fallback recovers a Status, log to cast.db `quality_gates` with `contract_passed = -1` (special sentinel meaning "recovered via file fallback").
   - Only treat as `BLOCKED` if both the retry AND the file fallback fail.

   - **Test-runner authoritative file truth (Phase 4.11):** When the dispatched agent is `test-runner` (or `subagent_type=test-runner`), the file at `~/.claude/agent-status/test-runner-*.json` is treated as MORE authoritative than the prose Status line — even when prose is present. This guards against the hallucination class observed 2026-05-11 where test-runner reported false BLOCKED on a green suite. Implementation:
     ```bash
     if [[ "$AGENT_NAME" == "test-runner" ]]; then
       STATUS_FILE=$(python3 -c "
import os, glob
files = glob.glob(os.path.expanduser('~/.claude/agent-status/test-runner-*.json'))
if files:
    files.sort(key=lambda f: os.path.getmtime(f), reverse=True)
    print(files[0])
" 2>/dev/null)
       if [[ -n "$STATUS_FILE" && -f "$STATUS_FILE" ]]; then
         FILE_MTIME=$(python3 -c "import os,sys; print(int(os.path.getmtime(sys.argv[1])))" "$STATUS_FILE" 2>/dev/null || echo 0)
         NOW=$(date +%s)
         AGE=$((NOW - FILE_MTIME))
         if [[ "$AGE" -le 300 ]]; then
           FILE_STATUS=$(python3 -c "import json; d=json.load(open('$STATUS_FILE')); print(d.get('status',''))" 2>/dev/null)
           # If file status differs from prose status, trust the file
           if [[ -n "$FILE_STATUS" && "$FILE_STATUS" != "$(echo "$STATUS_LINE" | grep -oE 'DONE|BLOCKED|DONE_WITH_CONCERNS|NEEDS_CONTEXT' | head -1)" ]]; then
             echo "[CAST] test-runner prose said $STATUS_LINE but file says $FILE_STATUS — trusting file."
             STATUS_LINE="Status: $FILE_STATUS (file-authoritative)"
           fi
         fi
       fi
     fi
     ```
   - This rule applies BEFORE the generic Phase 4.9 fallback — for test-runner, the file always wins.

3. Log validation result to cast.db:
   ```bash
   python3 -c "
   import sys; sys.path.insert(0, '$HOME/.claude/scripts')
   from cast_db import db_write, db_execute
   import datetime, os
   db_execute('''
       CREATE TABLE IF NOT EXISTS quality_gates (
           id TEXT PRIMARY KEY,
           session_id TEXT,
           batch_id INTEGER,
           agent_name TEXT,
           timestamp TEXT,
           status_line TEXT,
           contract_passed INTEGER,
           retry_count INTEGER
       )
   ''')
   db_write('quality_gates', {
       'id': os.urandom(8).hex(),
       'session_id': os.environ.get('CLAUDE_SESSION_ID', 'unknown'),
       'batch_id': $BATCH_ID,
       'agent_name': '$AGENT_NAME',
       'timestamp': datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
       'status_line': '$STATUS_LINE',
       'contract_passed': $CONTRACT_PASSED,
       'retry_count': $RETRY_COUNT
   })
   " 2>/dev/null || true
   ```
   Where:
   - `$BATCH_ID` = current batch id integer
   - `$AGENT_NAME` = agent name or subagent_type from the ADM entry
   - `$STATUS_LINE` = the extracted Status line text (e.g., "Status: DONE") or "MISSING" if not found
   - `$CONTRACT_PASSED` = 1 if valid Status line found on first try, 0 if retry was needed or Status missing
   - `$RETRY_COUNT` = 0 or 1

4. Route based on Status:
   - `Status: DONE` → mark task completed, write checkpoint, continue
   - `Status: DONE_WITH_CONCERNS` → log the concern text (the line following Status:), mark completed, continue
   - `Status: BLOCKED` or no Status line after retry → write checkpoint and stop: "Batch N blocked. Human intervention required. Blocker: [extracted reason or 'no Status line']"
   - `Status: NEEDS_CONTEXT` → stop and request clarification from the user before continuing

5. **File presence check** — after `Status: DONE` or `Status: DONE_WITH_CONCERNS`, run:
   ```bash
   git status --short
   git diff --stat HEAD | tail -20
   ```
   Then Read the 2-3 most critical files the agent claimed to modify (as listed in its Work Log or the plan task's "Files" section). Only mark the batch step complete after confirming the agent's claimed changes are present on disk. If git status shows no changes but the agent claimed edits, retry the agent once or escalate to the user — do NOT silently continue.

After each batch completes:
- Mark task `completed`
- Write checkpoint:
  ```bash
  mkdir -p ~/.claude/cast
  echo "[BATCH $BATCH_ID COMPLETE] $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$CHECKPOINT_FILE"
  ```
- Emit event:
  ```bash
  source ~/.claude/scripts/cast-events.sh
  cast_emit_event 'task_completed' 'orchestrate-skill' 'batch-<id>' '' '<summary>' '<STATUS>'
  ```
- Print `[BATCH N COMPLETE]`

**Token budget check (between batches):**
After each batch completes, check the session token budget:
```bash
python3 ~/.claude/scripts/cast-token-budget-check.py --threshold 50000 2>/dev/null
```
If exit code is 1 (over threshold), log a warning and consider compacting context before the next batch. Do not stop execution — this is advisory only.

After all batches complete (or on any early-exit path — blocked, turn limit, or abort), clear the env var:
```bash
unset CAST_ORCHESTRATE_ACTIVE
```

## Step 5 — Summarize

After all batches complete, print a brief summary (≤200 words): what each batch did, any concerns.

> **Note — VerifyPlanExecutionTool:** The native `VerifyPlanExecutionTool` (confirmed in Claude Code source) returns a PASS/FAIL/PARTIAL verdict after plan execution. When this tool is officially available in the tool registry, call it here before emitting the terminal event. Log the verdict to `cast.db quality_gates`. See `docs/native-tools-reference.md` for the full list of confirmed native tools.

Delete checkpoint:
```bash
rm -f "$CHECKPOINT_FILE"
```

Emit terminal event:
```bash
source ~/.claude/scripts/cast-events.sh
cast_emit_event 'task_completed' 'orchestrate-skill' 'session' '' 'All batches complete' 'DONE'
```

## Mandatory Chain Entries

The following agents automatically dispatch their successor agents when status = DONE:

- **code-writer** → code-reviewer
- **bash-specialist** → code-reviewer
- **debugger** → test-runner
- **security** → code-reviewer

These fire automatically after each upstream agent completes and should not be re-dispatched manually in the plan.

## Output Compression Rules
- Summarize each agent's response in **under 100 words**. Never reproduce content from the agent's spawn prompt.
- Never paste full tool output, file contents, or raw WebFetch results into your context.
- If your accumulated context exceeds ~30,000 tokens (roughly 15+ agent dispatches), perform inline compaction: discard completed batch details, keep only the status summary per batch.
- When passing context to the next batch, include only: (1) the plan's remaining batches, (2) a 1-sentence summary per completed batch, (3) any blocking issues.

## Agent Teams Integration (experimental)

When `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` is set in settings.json, the orchestrating session
can operate as a **team lead** in an Agent Team instead of using hub-and-spoke subagent
dispatch. In team-lead mode:

- Parallel batch agents become **teammates** with shared task lists
- The orchestrating session creates tasks via `TaskCreate` and teammates claim/complete them
- Fallback: if Agent Teams is not available or the flag is unset, standard hub-and-spoke
  dispatch via the Agent tool continues to work unchanged

This is additive — the existing dispatch model remains the default. Agent Teams is an
opt-in enhancement for parallel batches that benefit from peer-to-peer coordination.

## Truncation Fallback for Gate Agents

If `[CAST-TRUNCATED]` fires on a read-only gate agent (test-runner, code-reviewer, security):

1. **Do NOT auto-retry** — the truncation note says "do NOT auto-retry expensive agents."
2. **Inline fallback is permitted:**
   - For test-runner: run `bash tests/run.sh --tap 2>&1 | tail -20` inline and report counts.
   - For code-reviewer: read changed files, apply code-review checklist manually.
   - For security: grep for known anti-patterns (hardcoded keys, SQL injection, shell injection), defer deep reasoning review to next session.
3. **Log the fallback** in the Work Log as a concern: mark `Status: DONE_WITH_CONCERNS` and note which gate ran inline.
4. **Log to cast.db** as: `agent_name = '<role>-INLINE-FALLBACK'`, `contract_passed = 1` if the inline check found no issues, else `0`.
5. **If inline fallback cannot complete**, mark the batch `BLOCKED` and stop — do not attempt to continue.

## Rules

- Never skip a batch unless the user explicitly says to
- Maximum 4 agents per parallel batch
- Output discipline: summarize each agent in 3 sentences max. Never paste full agent output verbatim.
- If blocked after one retry: write checkpoint, stop, tell user how to resume with `/orchestrate resume`
