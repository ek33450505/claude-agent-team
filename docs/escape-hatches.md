# CAST Escape Hatches

An **escape hatch** is an environment variable that bypasses a safety guard. CAST embeds many guards in its hook pipeline to prevent destructive operations from running unchecked. When you need to override a guard (for CI, testing, or legitimate exceptions), set the corresponding escape hatch as a **leading environment variable assignment** before your command.

## Critical Design Principle

Escape hatches MUST appear as a **leading env var** on the command line itself, not inside messages, comments, or subsequent lines. This prevents accidental bypass via message injection.

**Valid:**
```bash
CAST_COMMIT_AGENT=1 git commit -m "message"
CAST_PUSH_OK=1 git push
CAST_KILL_OK=1 kill -9 $PID
```

**Invalid (will be blocked):**
```bash
# ✗ Inside commit message — blocked
git commit -m "CAST_COMMIT_AGENT=1 something something"

# ✗ Chained via echo — blocked
echo "CAST_PUSH_OK=1" && git push

# ✗ On a later line in a multi-line command — first line is scanned; blocks on that
SOME_VAR=x
CAST_COMMIT_AGENT=1 git commit  # ← This line is checked, but split_segments sees line 1 first
```

**Reference:** `scripts/pre-tool-guard.sh` § Line 10-15 for the policy engine; `scripts/cast-command-guard.py` § §39, 78 for per-segment semantics.

---

## Escape Hatches by Category

### Git / Commit Safety

| Variable | What it bypasses | Guarding Script | Example | Caveat |
|----------|------------------|-----------------|---------|--------|
| `CAST_COMMIT_AGENT=1` | Raw `git commit` (without using commit agent) | `scripts/pre-tool-guard.sh` (line 160) | `CAST_COMMIT_AGENT=1 git commit -m "message"` | Hard block (exit 2). Escape hatch required because agents should orchestrate commits to ensure co-author trailers and status logging. Emergency-only bypass. |
| `CAST_PUSH_OK=1` | Raw `git push` (without ensuring code-reviewer has run first) | `scripts/pre-tool-guard.sh` (line 178) | `CAST_PUSH_OK=1 git push` | Hard block (exit 2). Designed to enforce the Writer/Reviewer pattern. Use `commit` agent workflow instead for normal flow. |
| `CAST_STASH_OK=1` | Any `git stash` operation (push, pop, apply, drop, clear, etc.) | `scripts/pre-tool-guard.sh` (line 188) | `CAST_STASH_OK=1 git stash pop` | Hard block (exit 2). Guards against the 2026-05-19 incident where bare `git stash pop` resurrected abandoned stashes from other sessions. Only use if you have a documented reason. |
| `CAST_POLICY_OVERRIDE=1` | Path-based policies defined in `config/policies.json` or `~/.claude/config/policies.json` | `scripts/pre-tool-guard.sh` (line 28) | `CAST_POLICY_OVERRIDE=1 <write or edit command>` | Hard block (exit 2) on violations. Audit-logged to `~/.claude/logs/audit.jsonl` when used. Document your reason — this is a policy gate, not a lint. |

### Destructive Operations

| Variable | What it bypasses | Guarding Script | Example | Caveat |
|----------|------------------|-----------------|---------|--------|
| `CAST_KILL_OK=1` | Process-kill guards: blocks `pkill`, `killall`, and `kill` of process groups / all processes (targets 0, -1, negative pids) | `scripts/cast-command-guard.py` (line 9–19) | `CAST_KILL_OK=1 pkill -9 -f my_pattern` | Hard block (exit 2). Individual PIDs (`kill -9 $PID`) are allowed; mass-kill is not. Per-segment escape hatch (see §39). |
| `CAST_RM_OK=1` | Recursive rm guard: blocks `rm -rf` of protected paths (`/`, `~`, `~/.claude`, `${HOME}/.claude`) | `scripts/cast-command-guard.py` (line 21–33) | `CAST_RM_OK=1 rm -rf ~/.claude/cache` | Hard block (exit 2). Protects home root and `.claude` subtree only; other home subpaths (`rm -rf ~/Projects/x/node_modules`) are allowed. Per-segment escape hatch. |

### Hook / Lint Bypass (pre-commit, pre-push, post-merge)

| Variable | What it bypasses | Guarding Script | Example | Caveat |
|----------|------------------|-----------------|---------|--------|
| `CAST_SKIP_LINTS=1` | Lints 1 (Python cold-start counter) and 2 (SQL injection detector) in pre-commit | `.githooks/pre-commit` (line 267) | `CAST_SKIP_LINTS=1 git commit -m "..."` | Advisory bypass (exit 0). Does NOT bypass orphan-script lint or hook-contract validation. Emergency-only; address violations before next merge. |
| `CAST_SKIP_SELF_LINTS=1` | Self-lints: byte-budget, hook-wiring, agent-roster, agent-boilerplate, blast-radius in pre-commit | `.githooks/pre-commit` (line 308) | `CAST_SKIP_SELF_LINTS=1 git commit -m "..."` | Advisory bypass (exit 0). Emergency-only. Address violations before next merge. |
| `CAST_SKIP_HOOK_VALIDATE=1` | Hook contract validator (pre-commit, on settings.json or managed-settings.d/*.json changes) | `.githooks/pre-commit` (line 256) | `CAST_SKIP_HOOK_VALIDATE=1 git commit -m "..."` | Advisory bypass (exit 0). Only blocks on ERRORS (exit 2); warnings are non-blocking. |
| `CAST_SKIP_PLUGIN_DRIFT=1` | Plugin-drift guard (pre-commit, when agents/core, skills, commands, scripts, or managed-settings.d are staged) | `.githooks/pre-commit` (line 355) | `CAST_SKIP_PLUGIN_DRIFT=1 git commit -m "..."` | Advisory bypass (exit 0). Regenerate plugin/ before next merge to avoid CI failure. |
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
| `CAST_REPO_CLASS` | Marks repo as `personal` or `work` (default: inferred by `cast-stack-detect.sh`) | `scripts/cast-cwdchanged-hook.sh` (reads from `.claude/cast.json` via env); also set in `scripts/cast-stack-inject.sh` | Read/written via `.claude/cast.json` or `cast-stack-inject.sh` | Not an escape hatch; a repo classification. Affects co-author trailer style and deployment behavior (see `~/.claude/rules/work-projects.md`). |
| `CAST_JARVIS_LOCAL=1` | Override sunset jobs gate (re-enable local cron jobs that are sunset in the schedule) | `scripts/cast-cron-setup.sh` (line 17) | `CAST_JARVIS_LOCAL=1 bash ~/.claude/scripts/cast-cron-setup.sh` | Local-machine policy. Sunset jobs (morning, summary, cron-health) are disabled by default; set this flag to re-enable. Re-running `cast-cron-setup.sh` without the flag keeps them disabled. |
| `CAST_OVERLAY_REPO` | Git URL of the private overlay repo (required for `cast-overlay-sync.sh`; no default) | `scripts/cast-overlay-sync.sh` (line 8); reads from env or `~/.claude/config/cast-overlay-repo` | `CAST_OVERLAY_REPO=https://github.com/user/cast-private.git bash ~/.claude/scripts/cast-overlay-sync.sh` | Config variable, not a guard bypass. If not set via env, script reads from `~/.claude/config/cast-overlay-repo` (gitignored). |

### Internal / Meta (Framework)

| Variable | Purpose | Set / Checked By | Notes |
|-----------|---------|------------------|-------|
| `CLAUDE_SUBPROCESS=1` | Framework flag: marks a process as a CAST-managed subprocess (managed agents, hook subprocesses). When set, hooks skip guards (consistency + latency). | CAST hook infrastructure; set by Claude Code or `cast-managed-agent.sh` | Not user-facing. Agents and scripts should never set this themselves. When set, `pre-tool-guard.sh`, `cast-command-guard.py`, and most event hooks exit 0 without processing. |
| `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` | Enable Claude Code's Managed Agents (beta, Anthropic feature). Set in `managed-settings.d/00-env.json` (line 4). | Claude Code runtime; stored in `managed-settings.d/00-env.json` | Not a guard bypass; a feature flag. Required for managed-agent dispatches to work. Part of the CAST plugin's managed-agents support (see `docs/managed-agents-reference.md`). |

---

## Safety Notes

1. **Audit Logging:** `CAST_POLICY_OVERRIDE=1` is audit-logged to `~/.claude/logs/audit.jsonl` for compliance tracking.

2. **Per-Segment Semantics:** Command-guard escapes (`CAST_KILL_OK=1`, `CAST_RM_OK=1`) apply only to the shell segment carrying them. Each segment (separated by `;`, `&`, `&&`, `\n`, etc.) is evaluated independently, so a later segment without the hatch is still blocked.

3. **One-Time Emergency Bypasses:** Lints and hook gates marked "emergency-only" (e.g., `CAST_SKIP_LINTS=1`, `CAST_SKIP_SELF_LINTS=1`) are meant for rare, documented exceptions. They do NOT address the underlying violation — you must fix the issue before the next merge.

4. **Post-Merge Hook Behavior:** The `post-merge` hook exits advisably (exit code 0 always), so `CAST_SKIP_POST_MERGE_INSTALL=1` does not block the merge; it simply skips the auto-reinstall step.

5. **Docker / Isolation:** Some guards (`CAST_SKIP_PII_CHECK`, `CAST_SKIP_STATS_PUSH`) are routinely used in CI when running in isolated containers. Set them as needed for your CI/CD flow, but document the reason.

6. **Default Behavior:** Most escape hatches are ADVISORY (guard is a suggestion, exit 0). A few are HARD blocks (exit 2): the git safety guards (`CAST_COMMIT_AGENT`, `CAST_PUSH_OK`, `CAST_STASH_OK`), destructive-op guards (`CAST_KILL_OK`, `CAST_RM_OK`), and the policy override (`CAST_POLICY_OVERRIDE`). Hard blocks cannot be silently bypassed — the hatch must be explicitly set.

---

## See Also

- **Hook Guard Architecture:** `scripts/pre-tool-guard.sh`, `scripts/cast-command-guard.py`
- **Policy Engine:** `config/policies.json`, `~/.claude/config/policies.json`
- **Git Workflow:** `~/.claude/rules/working-conventions.md` § Code Quality, Commits
- **Managed Agents:** `docs/managed-agents-reference.md`
- **Work Projects:** `~/.claude/rules/work-projects.md`
