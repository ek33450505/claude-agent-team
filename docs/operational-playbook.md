# CAST Operational Playbook

> Operational and recovery procedures moved off the always-on `working-conventions.md` surface
> (v7.5 Phase 1, 2026-06-09). These apply in specific situations — multi-terminal work, worktree
> recovery, branch grooming, pre-push CI checks, workflow closures — not every session.
> The behavioral core (Planning, Code Quality, Testing, Commits, Context Management, Branch Naming,
> Stat/Fact and Memory Verification) stays in `rules/working-conventions.md`.

## Worktree Recovery

- `backend-writer`, `frontend-writer`, `debugger`, `test-writer`, `security`, and `frontend-qa` no longer auto-isolate into git worktrees (`isolation: worktree` removed from frontmatter). The agent runs in the orchestrator's working tree.
- A `SubagentStop` detection hook (`cast-subagent-worktree-check.sh`) fires after every dispatch of these agents. If the harness still spawns a worktree as a side effect, the hook auto-removes it when clean (banner: `✓ AGENT-WORKTREE CLEANUP`) and escalates when dirty (banner: `⚠ AGENT-WORKTREE DETECTED (DIRTY)`). All anomalies log to `cast.db worktree_anomalies`.
- If the dirty banner appears, copy the listed files from the worktree path to the active branch, then `git worktree remove --force --force <path>`.
- Always verify agent-reported file changes by reading the files after the agent completes.

## Multi-Terminal Coordination

When running more than one terminal on the same repo simultaneously:

- **Explicit stage lists:** Never use `git add -A` or `git add .` — always stage by explicit file path. This prevents Terminal B from committing files that Terminal A is mid-edit on.
- **Pull before push:** `git pull --rebase origin <branch>` before every push. If the rebase fails, resolve; never force-push shared history.
- **Pre-commit status check:** Run `git status` immediately before staging to surface any cross-stream artifacts (unexpected modifications or untracked files from the other terminal's agent work).
- **Sequential push order is the proven safe pattern:** Finish Terminal A's entire commit chain, push it, then Terminal B rebases and pushes. Parallel pushes to the same branch cause race-condition overwrites.
- **Parallel research dispatches are safe:** Read-only agent work (researcher, code-reviewer) can run in parallel across terminals without coordination. Writes must be sequential.
- **No cross-terminal agent scope overlap:** If Terminal A owns a file, Terminal B agents must not touch it, even to "fix" adjacent issues. Scope creep from one terminal's agents is the primary cause of mid-session reverts.

## Post-Push CI Verification

- After pushing commits that could affect CI, check for hardcoded absolute paths, platform-specific modules (e.g., FTS5 on macOS runners), and stale version lookups after package renames.
- Run the test suite locally with CI-equivalent paths before pushing when possible (with an ISOLATED temp HOME — never the real one).

## Branch & Worktree Hygiene

- **Grooming policy:**
  - `worktree-agent-*` branches older than 7 days are candidates for deletion.
  - `feature/*` and `fix/*` branches that are merged into `main` AND whose remote tracking ref is `[gone]` are candidates for deletion.
- **Hard whitelist (never deleted):** `main`, `feat/*`, `feature/cast-v7-*`, any branch currently checked out in a worktree.
- **Manual usage:**
  - `cast clean` — dry-run preview (default, no changes made)
  - `cast clean --apply` — delete stale branches
  - `cast clean --apply --worktrees` — delete stale branches and prune dead worktree directories
- **Weekly automated dry-run report:** `scripts/cast-branch-groomer-schedule.sh` writes a dated report to `~/.claude/reports/branch-grooming-<date>.md`. Review the report, then run `cast clean --apply` when ready.
- **Hard rule:** Any agent or skill that creates a branch or worktree MUST clean up on success. The groomer is a safety net, not the primary cleanup mechanism. Orphaned branches from failed or abandoned agent runs must be cleaned manually.
- **CI contract validation:** The `hook-contract-validation` job in `.github/workflows/bats-ci.yml` validates `hookSpecificOutput` format. Non-spec output is a hard CI fail — fix before pushing.

## Workflow Closures (Phase 5b)

- **Auto mode:** `defaultMode: "auto"` is set but has a session-start bug — use `--permission-mode auto` until upstream fixes it.
- **Routines:** Prefer `/schedule` over local cron for scheduled CAST jobs.
- **Forked subagents:** Use `scripts/cast-managed-agent.sh <agent> <prompt> --fork` to spawn agents on Anthropic infrastructure with `CLAUDE_CODE_FORK_SUBAGENT=1` set. This replaces worktree isolation for parallel work — Managed Agents isolate execution on cloud infrastructure, eliminating filesystem contention. Cannot spawn sub-subagents — no nested orchestration.
- **Task Budgets:** Opus 4.7 API beta only — no Claude Code surface yet; revisit when GA.
