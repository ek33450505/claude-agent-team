# CAST Escape Hatches

An **escape hatch** is an environment variable that bypasses a safety guard. CAST embeds many guards in its hook pipeline to prevent destructive operations from running unchecked. When you need to override a guard (for CI, testing, or legitimate exceptions), set the corresponding escape hatch as a **leading environment variable assignment** before your command.

## Critical Design Principle

Escape hatches MUST appear as a **leading env var** on the command line itself, not inside messages, comments, or subsequent lines. This prevents accidental bypass via message injection.

**Valid:**
```bash
CAST_COMMIT_AGENT=1 git commit -m "message"
CAST_PUSH_OK=1 git push
CAST_KILL_OK=1 kill -9 $PID

# ✓ On a LATER LINE of a multi-line command — every line is scanned, so this is honoured.
#   (Before v10 SEC-1 only line 1 was scanned. Same-line && and ; chaining always worked;
#    the newline was the whole bug.)
SOME_VAR=x
CAST_COMMIT_AGENT=1 git commit  # ← hatch is on the same segment as the command

# ✓ Optional reason annotation (any of the 16 git hatches, CAST v10 I-3b Unit 2b) —
#   goes AFTER the hatch, quoted if it contains spaces:
CAST_RESET_OK=1 CAST_HATCH_REASON="rebasing onto main" git reset --hard
```

**Invalid (will be blocked):**
```bash
# ✗ Inside commit message — blocked
git commit -m "CAST_COMMIT_AGENT=1 something something"

# ✗ Chained via echo — blocked
echo "CAST_PUSH_OK=1" && git push
```

**Important:** The guard scans every line and splits on `;`, `&&`, `||`, and `|`. Comments and heredoc bodies are also scanned, so prose that merely names a guarded command will block and requires the hatch. This is deliberate — a hatchable false block was chosen over a silent bypass.

**Reference:** `scripts/cast-git-guard.py` holds the git blocks and the Write/Edit policy engine; `scripts/pre-tool-guard.sh` is a thin wrapper that `exec`s it (the live hook routes through `cast-pretool-dispatch.py`). `scripts/cast-command-guard.py` holds the per-segment mass-kill and `rm -rf` guards. Symbols are cited rather than line numbers deliberately — the previous line references had rotted past the end of a 24-line file.

---

## Escape Hatches by Category

### Git / Commit Safety

| Variable | What it bypasses | Guarding Script | Example | Caveat |
|----------|------------------|-----------------|---------|--------|
| `CAST_COMMIT_AGENT=1` | Raw `git commit` (without using commit agent) | `scripts/cast-git-guard.py` (`_COMMIT_BLOCK`) | `CAST_COMMIT_AGENT=1 git commit -m "message"` | Hard block (exit 2). Escape hatch required because agents should orchestrate commits to ensure co-author trailers and status logging. Emergency-only bypass. |
| `CAST_PUSH_OK=1` | Raw `git push` (without ensuring code-reviewer has run first) | `scripts/cast-git-guard.py` (`_PUSH_BLOCK`) | `CAST_PUSH_OK=1 git push` | Hard block (exit 2). Designed to enforce the Writer/Reviewer pattern. Use `commit` agent workflow instead for normal flow. |
| `CAST_STASH_OK=1` | Any `git stash` operation (push, pop, apply, drop, clear, etc.) | `scripts/cast-git-guard.py` (`_STASH_BLOCK`) | `CAST_STASH_OK=1 git stash pop` | Hard block (exit 2). Guards against the 2026-05-19 incident where bare `git stash pop` resurrected abandoned stashes from other sessions. Only use if you have a documented reason. |
| `CAST_RESET_OK=1` | `git reset --hard`, `--merge`, `--keep` | `scripts/cast-git-guard.py` | `CAST_RESET_OK=1 git reset --hard HEAD~1` | Hard block (exit 2). Destructive reset variants are guarded; soft reset remains allowed. |
| `CAST_CLEAN_OK=1` | `git clean` (non-dry-run) | `scripts/cast-git-guard.py` | `CAST_CLEAN_OK=1 git clean -fd` | Hard block (exit 2). Dry-run mode (`-n`) is always allowed. |
| `CAST_CHECKOUT_OK=1` | `git checkout <pathspec>` and forced switches (`-f`, `--discard-changes`) | `scripts/cast-git-guard.py` | `CAST_CHECKOUT_OK=1 git checkout -f main` | Hard block (exit 2). Guarded pathname and forced-switch variants only; navigation-only checkouts remain allowed. |
| `CAST_RESTORE_OK=1` | `git restore` (worktree forms) | `scripts/cast-git-guard.py` | `CAST_RESTORE_OK=1 git restore --worktree <path>` | Hard block (exit 2). Index-only restores remain allowed. |
| `CAST_SWITCH_OK=1` | `git switch -f`, `--discard-changes` | `scripts/cast-git-guard.py` | `CAST_SWITCH_OK=1 git switch -f feature/x` | Hard block (exit 2). Clean switches remain allowed; discarding local changes requires the hatch. |
| `CAST_GIT_RM_OK=1` | `git rm -f` | `scripts/cast-git-guard.py` | `CAST_GIT_RM_OK=1 git rm -f <path>` | Hard block (exit 2). Guarded forced-removal variant only. |
| `CAST_BRANCH_OK=1` | `git branch -D`, `-M`, `-f` (destructive branch operations) | `scripts/cast-git-guard.py` | `CAST_BRANCH_OK=1 git branch -D stale-branch` | Hard block (exit 2). Read-only branch queries remain allowed. |
| `CAST_WORKTREE_OK=1` | `git worktree remove -f` | `scripts/cast-git-guard.py` | `CAST_WORKTREE_OK=1 git worktree remove -f <path>` | Hard block (exit 2). Clean worktree removal remains allowed. |
| `CAST_UPDATE_REF_OK=1` | `git update-ref -d`, `--stdin`, and ref overwrites | `scripts/cast-git-guard.py` | `CAST_UPDATE_REF_OK=1 git update-ref -d refs/heads/old` | Hard block (exit 2). Low-level ref mutation requires this hatch. |
| `CAST_FILTER_BRANCH_OK=1` | `git filter-branch` | `scripts/cast-git-guard.py` | `CAST_FILTER_BRANCH_OK=1 git filter-branch -f --tree-filter '...'` | Hard block (exit 2). Rewriting history requires explicit acknowledgement. |
| `CAST_REFLOG_OK=1` | `git reflog expire`, `delete` | `scripts/cast-git-guard.py` | `CAST_REFLOG_OK=1 git reflog delete refs/heads/old@{0}` | Hard block (exit 2). Part of the recovery path (see `CAST_GC_OK` and `CAST_PRUNE_OK` below). Reflog entries are what recovered a destroyed reviewed diff on 2026-08-17. |
| `CAST_GC_OK=1` | `git gc` with an explicit prune date; also gates git config writes to `gc.reflogExpire`, `gc.reflogExpireUnreachable`, `gc.pruneExpire` | `scripts/cast-git-guard.py` | `CAST_GC_OK=1 git gc --prune=now` | Hard block (exit 2). Bare `git gc` (honouring git's two-week default) remains allowed; explicit prune dates require the hatch. Part of the recovery path. |
| `CAST_PRUNE_OK=1` | `git prune` (non-dry-run) | `scripts/cast-git-guard.py` | `CAST_PRUNE_OK=1 git prune` | Hard block (exit 2). Dry-run mode (`-n`) is always allowed. Part of the recovery path — unreachable objects are what enabled recovery of destroyed reviewed work. |
| `CAST_POLICY_OVERRIDE=1` | Path-based policies defined in `config/policies.json` or `~/.claude/config/policies.json` | `scripts/cast-git-guard.py` (`_policy_evaluate`) | `CAST_POLICY_OVERRIDE=1 <write or edit command>` | Hard block (exit 2) on violations. Audit-logged to `~/.claude/logs/audit.jsonl` when used. Document your reason — this is a policy gate, not a lint. |
| `CAST_HATCH_REASON=<text>` | Not a hatch itself — an OPTIONAL annotation on any of the 16 git hatches above. Records the *why*, not just the who/which/when. | `scripts/cast-git-guard.py` (`record_hatch_use`, inside `_git_evaluate_impl`) | `CAST_RESET_OK=1 CAST_HATCH_REASON="rebasing onto main" git reset --hard` | Must come AFTER the hatch variable in the same segment (the hatch itself must still be first — see Safety Note 8). Quote if it contains spaces. Sets `ack_events.has_reason=1` and stores the reason text as `ack_events.value` (overwriting the hatch's own recorded value, which is always a bare `1`/truthy token and carries no information once an *_ALLOW regex has matched on it — nothing is lost). Optional: omit it and the hatch's own value is recorded exactly as before. Only recorded when the hatch actually averted a block (same block-averted semantics as every other hatch — see Safety Note 10). |

### Destructive Operations

| Variable | What it bypasses | Guarding Script | Example | Caveat |
|----------|------------------|-----------------|---------|--------|
| `CAST_KILL_OK=1` | Process-kill guards: blocks `pkill`, `killall`, and `kill` of process groups / all processes (targets 0, -1, negative pids) | `scripts/cast-command-guard.py` (line 9–19) | `CAST_KILL_OK=1 pkill -9 -f my_pattern` | Hard block (exit 2). Individual PIDs (`kill -9 $PID`) are allowed; mass-kill is not. Per-segment escape hatch (see §39). |
| `CAST_RM_OK=1` | Recursive rm guard: blocks `rm -rf` of protected paths (`/`, `~`, `~/.claude`, `${HOME}/.claude`) | `scripts/cast-command-guard.py` (line 21–33) | `CAST_RM_OK=1 rm -rf ~/.claude/cache` | Hard block (exit 2). Protects home root and `.claude` subtree only; other home subpaths (`rm -rf ~/Projects/x/node_modules`) are allowed. Per-segment escape hatch. |
| `CAST_NEON_BRANCH_DELETE_OK=1` | Neon database branch deletion (CI/cleanup automation) | `scripts/cast-neon.sh` | `CAST_NEON_BRANCH_DELETE_OK=1 bash scripts/cast-neon.sh branch-delete <project_id> <branch_id>` | The script refuses to proceed without the hatch. Recording is attempted best-effort and can fail silently. `--dry-run` is exempt from the gate and writes no ack row. Use only for documented automation. |
| `CAST_CONSOLIDATE_SKIP_BACKUP=1` | Memory consolidation backup skip (agent-memory consolidation, `scripts/cast-memory-consolidate.py`) | `scripts/cast-memory-consolidate.py` | `CAST_CONSOLIDATE_SKIP_BACKUP=1 python3 scripts/cast-memory-consolidate.py` | The script refuses to proceed without the hatch. Skips creating a backup before consolidating agent memory. Use only if you have a separate backup strategy. |

### Hook / Lint Bypass (pre-commit, pre-push, post-merge)

| Variable | What it bypasses | Guarding Script | Example | Caveat |
|----------|------------------|-----------------|---------|--------|
| `CAST_SKIP_LINTS=1` | Lints 1 (Python cold-start counter) and 2 (SQL injection detector) in pre-commit | `.githooks/pre-commit` (line 267) | `CAST_SKIP_LINTS=1 git commit -m "..."` | Advisory bypass (exit 0). Does NOT bypass orphan-script lint or hook-contract validation. Emergency-only; address violations before next merge. |
| `CAST_SKIP_SELF_LINTS=1` | Self-lints: byte-budget, hook-wiring, agent-roster, agent-boilerplate, blast-radius in pre-commit | `.githooks/pre-commit` (line 308) | `CAST_SKIP_SELF_LINTS=1 git commit -m "..."` | Advisory bypass (exit 0). Emergency-only. Address violations before next merge. |
| `CAST_SKIP_HOOK_VALIDATE=1` | Hook contract validator (pre-commit, on settings.json or managed-settings.d/*.json changes) | `.githooks/pre-commit` (line 256) | `CAST_SKIP_HOOK_VALIDATE=1 git commit -m "..."` | Advisory bypass (exit 0). Only blocks on ERRORS (exit 2); warnings are non-blocking. |
| `CAST_SKIP_PLUGIN_DRIFT=1` | Plugin-drift guard (pre-commit, when agents/core, skills, commands, scripts, or managed-settings.d are staged) | `.githooks/pre-commit` (line 355) | `CAST_SKIP_PLUGIN_DRIFT=1 git commit -m "..."` | Advisory bypass (exit 0). Regenerate plugin/ before next merge to avoid CI failure. |
| `CAST_SKIP_RECONCILE=1` | Commit-provenance reconcile gate (pre-push, `scripts/cast-commit-reconcile.py`) | `scripts/cast-commit-reconcile.py` | `CAST_SKIP_RECONCILE=1 git push` | Advisory bypass (exit 0). Skips verification that the commit session is recorded in cast.db. Emergency-only; use `CAST_RECONCILE_ACK=1` (below) for sanctioned false-blocks. |
| `CAST_RECONCILE_ACK=1` | Sanctioned acknowledgement when the commit-provenance reconcile gate false-blocks on empty session_id or squash merges (pre-push) | `scripts/cast-commit-reconcile.py` | `CAST_RECONCILE_ACK=1 git push` | Advisory bypass (exit 0). Use when you have verified the gate's condition is a legitimate false-positive (empty session from a SendMessage resume, or a squash merge without a session context). |
| `CAST_SKIP_LEDGER_CHECK=1` | Ledger-drift gate for `docs/test-skip-ledger.md` reconciliation (pre-push, `scripts/cast-check-skip-ledger.sh`) | `scripts/cast-check-skip-ledger.sh` | `CAST_SKIP_LEDGER_CHECK=1 git push` | Advisory bypass (exit 0). Update the `**Total call sites: N** across M files` line in `docs/test-skip-ledger.md`; run `bash scripts/cast-check-skip-ledger.sh` to see both the recorded and the actual numbers. |
| `CAST_SKIP_UBUNTU_CHECK=1` | Ubuntu-specific check gate (pre-push, `scripts/pre-push-ubuntu-check.sh`) | `scripts/pre-push-ubuntu-check.sh` | `CAST_SKIP_UBUNTU_CHECK=1 git push` | Advisory bypass (exit 0). Skips verification of Ubuntu-compatibility markers in BATS tests. |
| `CAST_SKIP_DOCS_DELETE=1` | Docs-deletion guard (pre-push, `scripts/check-docs-deletion.sh`) prevents accidental doc removal | `scripts/check-docs-deletion.sh` | `CAST_SKIP_DOCS_DELETE=1 git push` | Advisory bypass (exit 0). Detects deletions in `docs/` and gates them for review. Use only if you have verified the deletion is intentional. |
| `CAST_SKIP_POST_COMMIT_PROVENANCE=1` | Post-commit provenance logging (`.githooks/post-commit`, which writes to `~/.claude/logs/post-commit-provenance.log`) | `.githooks/post-commit` | `CAST_SKIP_POST_COMMIT_PROVENANCE=1 git commit -m "..."` | Advisory bypass (exit 0). Skips post-commit provenance logging. Use only if you're managing logging manually. |
| `CAST_SKIP_BATS_PUSH=1` | BATS regression test gate during push (pre-push, isolated runner) | `.githooks/pre-push` | `CAST_SKIP_BATS_PUSH=1 git push` | Advisory bypass (exit 0). Skips test suite at push time (rarely set — tests only run on push when `CAST_RUN_BATS_PUSH=1` is active). |
| `CAST_RULES_BUDGET_ACK` | Byte-budget overflow acknowledgement for rules-core (`scripts/cast-lint-byte-budget.sh`) | `scripts/cast-lint-byte-budget.sh` | `CAST_RULES_BUDGET_ACK="reason for overflow" git commit -m "..."` | Advisory bypass (exit 0). **NOTE: This hatch requires a non-empty reason string (not `=1`), and the reason is echoed back.** Document why the budget was exceeded. |
| `CAST_SKIP_PII_CHECK=1` | PII / secret scan gate (pre-push) | `.githooks/pre-push` (line 20) | `CAST_SKIP_PII_CHECK=1 git push` | Advisory bypass (exit 0). Fails fast before test gates if secrets detected. Use only if you've manually verified no PII is being pushed. |
| `CAST_SKIP_STATS_PUSH=1` | Stats-drift ratchet gate (pre-push, cast-stats.json check) | `.githooks/pre-push` (line 37) | `CAST_SKIP_STATS_PUSH=1 git push` | Advisory bypass (exit 0). Run `bash scripts/gen-cast-stats.sh` to regenerate before next push. |
| `CAST_SKIP_DB_CONTRACT=1` | DB-contract ratchet gate (pre-push, schema violations check) | `.githooks/pre-push` (line 103) | `CAST_SKIP_DB_CONTRACT=1 git push` | Advisory bypass (exit 0). Fix with `python3 scripts/cast-db-contract.py --update-baseline` before next push. |
| `CAST_SKIP_RULES_DRIFT=1` | Rules-core manifest drift gate (pre-push) | `.githooks/pre-push` (line 125) | `CAST_SKIP_RULES_DRIFT=1 git push` | Advisory bypass (exit 0). Regenerate with `bash scripts/gen-rules-manifest.sh` before next push. |
| `CAST_SKIP_README_STRUCTURE=1` | README structure gate (pre-push, required sections check) | `.githooks/pre-push` (line 175) | `CAST_SKIP_README_STRUCTURE=1 git push` | Advisory bypass (exit 0). Add missing sections to README.md before next push. |
| `CAST_RUN_BATS_PUSH=1` | Opt-in BATS regression test gate (pre-push, disabled by default per 2026-06-02 policy) | `.githooks/pre-push` (line 203) | `CAST_RUN_BATS_PUSH=1 git push` | Advisory opt-in (exit 0 if pass, exit 1 if fail). Default is OFF to prevent accidental non-isolated BATS runs. Set to ON only when you want test-time validation at push. Routed through isolated runner (`tests/run.sh`). |
| `CAST_SKIP_POST_MERGE_INSTALL=1` | Post-merge auto-reinstall (post-merge, when agents/scripts/bin/rules-core change) | `.githooks/post-merge` (line 32) | `CAST_SKIP_POST_MERGE_INSTALL=1 git pull` | Advisory bypass (exit 0). Post-merge hook exits advisably; hook failure never breaks a merge. Use if you're managing install.sh manually. |

### Install / Setup

| Variable | What it bypasses | Guarding Script | Example | Caveat |
|----------|------------------|-----------------|---------|--------|
| `CAST_INSTALL_FORCE=1` | Dirty-tree guard in install.sh (refuses to overwrite uncommitted edits in agents/, scripts/, bin/, rules-core/) | `install.sh` (line 11) | `CAST_INSTALL_FORCE=1 bash install.sh` | Hard block (exit 1) on dirty tree, unless flag is set. For CI / test harnesses that manage git state themselves. Skips the safety check; use carefully. |

### Runtime Config / Behavior

| Variable | Purpose | Set / Read By | Example | Notes |
|----------|---------|---------------|---------|-------|
| `CAST_DB_PATH` | Override default SQLite database path (default: `~/.claude/cast.db`) | All scripts via `os.environ.get('CAST_DB_PATH', ...)` pattern; Python modules `scripts/cast_db.py`, `scripts/cast-migrate.py`, etc. | `CAST_DB_PATH=/tmp/test.db python3 scripts/cast_db.py` | Not a guard bypass; a config override. Useful for tests and isolated runs. |
| `CLAUDE_CODE_SCRIPT_CAPS` | Cap on Bash tool invocations per session (default in `managed-settings.d/00-env.json`: 100) | Claude Code runtime; stored in `managed-settings.d/00-env.json` (line 7) | Set in `managed-settings.d/00-env.json`; affects all Claude sessions | Prevents runaway loops. Not an env escape hatch — it's a config setting. Modify in `managed-settings.d/00-env.json` or via Claude Code settings UI. |
| `CAST_REPO_CLASS` | Marks repo as `personal` or `work` (default: inferred by `cast-stack-detect.sh`) | `scripts/cast-cwdchanged-hook.sh` (reads from `.claude/cast.json` via env) | Read/written via `.claude/cast.json` | Not an escape hatch; a repo classification. Affects co-author trailer style and deployment behavior (see `~/.claude/rules/work-projects.md`). |
| `CAST_JARVIS_LOCAL=1` | Override sunset jobs gate (re-enable local cron jobs that are sunset in the schedule) | `scripts/cast-cron-setup.sh` (line 17) | `CAST_JARVIS_LOCAL=1 bash ~/.claude/scripts/cast-cron-setup.sh` | Local-machine policy. Sunset jobs (morning, summary, cron-health) are disabled by default; set this flag to re-enable. Re-running `cast-cron-setup.sh` without the flag keeps them disabled. |
| `CAST_OVERLAY_REPO` | Git URL of the private overlay repo (required for `cast-overlay-sync.sh`; no default) | `scripts/cast-overlay-sync.sh` (line 8); reads from env or `~/.claude/config/cast-overlay-repo` | `CAST_OVERLAY_REPO=https://github.com/user/cast-private.git bash ~/.claude/scripts/cast-overlay-sync.sh` | Config variable, not a guard bypass. If not set via env, script reads from `~/.claude/config/cast-overlay-repo` (gitignored). |
| `CAST_RULES_SYNC_ACK` | Acknowledgement flag for non-interactive rules-core sync (`scripts/cast-rules-sync.sh --apply`) | `scripts/cast-rules-sync.sh` | `CAST_RULES_SYNC_ACK="<reason>" bash scripts/cast-rules-sync.sh --apply` | Required for non-interactive (headless) application of rules. Takes a non-empty reason string (not `=1`). Unset or falsy, the script requires manual approval at each step. |
| `CAST_ROUTINE_SKIP_MCP_CHECK=1` | Skip MCP server availability check in routine runner (`scripts/cast-routine-runner.sh`) | `scripts/cast-routine-runner.sh` | `CAST_ROUTINE_SKIP_MCP_CHECK=1 bash scripts/cast-routine-runner.sh` | Advisory skip (exit 0 if skipped). Skips pre-flight validation of MCP tool availability. Use only if you've verified tooling manually. |

### Internal / Meta (Framework)

| Variable | Purpose | Set / Checked By | Notes |
|-----------|---------|------------------|-------|
| `CLAUDE_SUBPROCESS=1` | Framework flag: marks a process as a CAST-managed subprocess (managed agents, hook subprocesses). When set, the Write/Edit-policy engine, egress recording, and dispatch-capture are skipped (consistency + latency) — git-guard and command-guard destructive-op blocks still fire unconditionally. | CAST hook infrastructure; set by Claude Code or `cast-managed-agent.sh` | Not user-facing. Agents and scripts should never set this themselves. Most event hooks exit 0 without processing when set — but `pre-tool-guard.sh`/`cast-git-guard.py` (commit/push/stash) and `cast-command-guard.py` (mass-kill, `rm -rf`) are exceptions: their destructive-op guards run before the `CLAUDE_SUBPROCESS` check and still hard-block. |
| `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` | Enable Claude Code's Managed Agents (beta, Anthropic feature). Set in `managed-settings.d/00-env.json` (line 4). | Claude Code runtime; stored in `managed-settings.d/00-env.json` | Not a guard bypass; a feature flag. Required for managed-agent dispatches to work. Part of the CAST plugin's managed-agents support (see `docs/managed-agents-reference.md`). |
| `CAST_REVIEW_BLOCK_OK=1` | Environment variable read by the approval gate (`cast_check_approvals` in `scripts/cast-events.sh`) to revert sticky-BLOCKED behaviour to newest-decision-wins | `scripts/cast-events.sh` | Set as an environment variable; no command-line invocation. The script refuses to proceed without the hatch. Recording is attempted best-effort and can fail silently. **SECURITY-RELEVANT:** This can let a later approval clear an earlier rejection; use only with explicit authorization. |

---

## Safety Notes

1. **Audit Logging:** `CAST_POLICY_OVERRIDE=1` is audit-logged to `~/.claude/logs/audit.jsonl` for compliance tracking.

2. **Per-Segment Semantics:** Command-guard escapes (`CAST_KILL_OK=1`, `CAST_RM_OK=1`) apply only to the shell segment carrying them. Each segment (separated by `;`, `&`, `&&`, `\n`, etc.) is evaluated independently, so a later segment without the hatch is still blocked.

3. **One-Time Emergency Bypasses:** Lints and hook gates marked "emergency-only" (e.g., `CAST_SKIP_LINTS=1`, `CAST_SKIP_SELF_LINTS=1`) are meant for rare, documented exceptions. They do NOT address the underlying violation — you must fix the issue before the next merge.

4. **Post-Merge Hook Behavior:** The `post-merge` hook exits advisably (exit code 0 always), so `CAST_SKIP_POST_MERGE_INSTALL=1` does not block the merge; it simply skips the auto-reinstall step.

5. **Docker / Isolation:** Some guards (`CAST_SKIP_PII_CHECK`, `CAST_SKIP_STATS_PUSH`) are routinely used in CI when running in isolated containers. Set them as needed for your CI/CD flow, but document the reason.

6. **Default Behavior:** Most escape hatches are ADVISORY (guard is a suggestion, exit 0). A few are HARD blocks (exit 2): the git safety guards (`CAST_COMMIT_AGENT`, `CAST_PUSH_OK`, `CAST_STASH_OK`), destructive-op guards (`CAST_KILL_OK`, `CAST_RM_OK`), and the policy override (`CAST_POLICY_OVERRIDE`). Hard blocks cannot be silently bypassed — the hatch must be explicitly set.

7. **Hatch Values are Matched Strictly:** The hatch value must be set as `VAR=1` (unquoted). Quoted forms like `CAST_RESET_OK="1"` are accepted; non-1 values like `CAST_RESET_OK="10"` are NOT and will still block. The hatch must be a real bash assignment prefix on the same shell segment as the command.

8. **The hatch must be the FIRST assignment.** When composing two env vars, the hatch goes first. Other `VAR=value` assignments may follow it, never precede it — the ALLOW patterns are anchored as `CAST_<OP>_OK=1\s+([A-Za-z_][A-Za-z0-9_]*=\S+\s+)*git`, so anything before the hatch breaks the anchor and the op blocks. Measured:

   ```bash
   CAST_COMMIT_AGENT=1 CAST_SKIP_PLUGIN_DRIFT=1 git commit   # ✓ allowed
   CAST_SKIP_PLUGIN_DRIFT=1 CAST_COMMIT_AGENT=1 git commit   # ✗ BLOCKED — hatch is not first
   ```

   Tolerance for assignments *after* the hatch was the v9.5.2 fix; nothing was ever allowed before it. The failure reads as "the hatch doesn't work" rather than "the hatch is in the wrong position", which is what makes it worth stating.

9. **Passing a message that names a guarded command.** Since the guard scans every line including heredoc bodies, a commit message mentioning e.g. a guarded op can itself trigger a block. Use `git commit -F <file>` rather than a `-m` heredoc, so the body never enters the scanned command string.

10. **All 16 Git Hatches Now Record (CAST v10 I-3b, Units 1a/1b-ii):** `scripts/cast_ack.py` and the `ack_events` table (migration 034) make bypasses a recorded primitive. As of Unit 1b-ii, ALL 16 git hatches (`CAST_COMMIT_AGENT`, `CAST_PUSH_OK`, `CAST_STASH_OK`, `CAST_RESET_OK`, `CAST_CLEAN_OK`, `CAST_CHECKOUT_OK`, `CAST_RESTORE_OK`, `CAST_SWITCH_OK`, `CAST_REFLOG_OK`, `CAST_GC_OK`, `CAST_PRUNE_OK`, `CAST_GIT_RM_OK`, `CAST_BRANCH_OK`, `CAST_WORKTREE_OK`, `CAST_UPDATE_REF_OK`, `CAST_FILTER_BRANCH_OK`) route through the same funnel in `scripts/cast-git-guard.py` (`record_hatch_use`, inside `_git_evaluate_impl`) and attempt recording via `_record_hatch()`. This corrects an earlier, now-stale version of this note that said only 4 hatches recorded — that was true through Unit 1a but not since Unit 1b-ii's merge. **Two NON-git hatches also record, and are not covered by the sixteen above:** `CAST_NEON_BRANCH_DELETE_OK` (`scripts/cast-neon.sh:270`) and `CAST_REVIEW_BLOCK_OK` (`scripts/cast-events.sh:577`). The earlier version of this note named both; do not read the "16 git hatches" scoping as meaning they stopped recording.

    Recording is **best-effort and gated on the hatch actually averting a block** — a hatched-but-harmless invocation (e.g. `CAST_RESET_OK=1 git reset --soft`, which never trips the destructive-flag check) records nothing, since nothing was ever going to block. The recording call is structurally unable to fail the operation it records (`try/except` in `_record_hatch`) and can fail silently, in which case the bypass still happens with no CAST-side record. Two stated limits apply: recording is capped at 8 per command (`_MAX_HATCH_RECORDS_PER_COMMAND`; a command padded with more hatched segments loses the later per-hatch rows, though a `CAST_HATCH_RECORD_CAP` sentinel row records *how many* were suppressed), and the value is recovered from the command text via `_hatch_value()`, so a value that cannot be parsed is not recorded. `CAST_COMMIT_AGENT` and `CAST_PUSH_OK` additionally still write the uncapped `COMMIT_HATCH_USED` / `PUSH_HATCH_USED` line to `~/.claude/logs/audit.jsonl` on every hatched use (not gated on block-averted), independent of the `ack_events` row. Note that a recorded entry means the operation was **permitted**, not that it ran — a PreToolUse hook evaluates commands that may never execute.

    **The recorded value can now carry a reason (CAST v10 I-3b Unit 2b):** set `CAST_HATCH_REASON=<text>` as a second leading assignment, after the hatch, in the same segment (see the `CAST_HATCH_REASON` table row above). When present, it overwrites the recorded `ack_events.value` with the reason text and sets `has_reason=1`; when absent, the row records the hatch's own value (`1`) exactly as before, with `has_reason=0`. A recorded reason is queryable via `cast ask`: `scripts/cast-ask-index.py` carries a `hatch` kind that indexes `ack_events` (including its `value` column) into the FTS search index. ⚠️ Indexing runs against the INSTALLED copy of that script, so a merged change is queryable only after `install.sh` delivers it — check with `grep -c '"kind": "hatch"' ~/.claude/scripts/cast-ask-index.py` rather than assuming. ⚠️ **The `value` is free text supplied by whoever used the hatch.** A reason that quotes a git command (e.g. `"git reset --hard was needed after a bad merge"`) can cause a row to be recorded for an op the command never ran — the verdict is unaffected, but do not read `value` as evidence of what executed.

---

## See Also

- **Hook Guard Architecture:** `scripts/pre-tool-guard.sh`, `scripts/cast-command-guard.py`
- **Policy Engine:** `config/policies.json`, `~/.claude/config/policies.json`
- **Git Workflow:** `~/.claude/rules/working-conventions.md` § Code Quality, Commits
- **Managed Agents:** `docs/managed-agents-reference.md`
- **Work Projects:** `~/.claude/rules/work-projects.md`
