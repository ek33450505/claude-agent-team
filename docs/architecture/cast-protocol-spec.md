# CAST Agent Protocol Specification

**Version:** 2.1.0
**Status:** Active
**Last Updated:** 2026-04-01

---

## Overview

CAST (Claude Agent Specialist Team) defines a protocol for multi-agent Claude Code systems. A CAST-compatible system routes user prompts to specialist agents, enforces quality gates, and propagates structured status signals across agent boundaries — all without requiring the user to manually orchestrate each step.

This specification covers the five protocol layers that make CAST agents interoperable:

1. **Status Blocks** — structured output format every agent must emit
2. **Escape Hatches** — env-var guards that allow trusted bypasses of hook enforcement
3. **Agent Dispatch Manifests** — declarative batch execution plans embedded in plan files
4. **Dispatch Directives** — hook-injected instructions Claude must obey
5. **Hook Event Model** — stdin/stdout contract for UserPromptSubmit, PreToolUse, PostToolUse

Supporting infrastructure documented separately:

6. **Shared Task Board** — cross-agent progress tracking at `~/.claude/task-board.json`
7. **Fan-out Dispatch** — parallel multi-agent execution patterns

---

## Section 1 — Status Block Format

Every CAST agent MUST output a Status block as the final content of its response. The Status block is the machine-readable contract between an agent and the session that dispatched it. It drives automatic routing, review triggers, and halt conditions.

### 1.1 Text Format (human-readable, always required)

The text format appears at the end of the agent's Markdown response. It MUST use the exact field names shown below. Field order is fixed within each status variant.

#### DONE

Used when the agent completed its task with no issues warranting follow-up.

```
Status: DONE
Summary: [one sentence describing what was accomplished]
```

Required fields: `Status`, `Summary`
Optional fields: none

#### DONE_WITH_CONCERNS

Used when the agent completed its task but identified issues that may need follow-up. This status triggers automatic `code-reviewer` dispatch via the `agent-status-reader.sh` PostToolUse hook.

```
Status: DONE_WITH_CONCERNS
Summary: [one sentence describing what was accomplished]
Concerns: [specific issues found — file/line references where possible]
Recommended agents:
  - <agent-name>: [specific reason referencing file/line]
  - <agent-name>: [specific reason referencing file/line]
```

Required fields: `Status`, `Summary`, `Concerns`
Optional fields: `Recommended agents` — include only when actionable follow-up is warranted

The `Recommended agents:` subsection lists the exact agent names (matching entries in the agent registry) and a specific reason for each. The main session decides whether to dispatch — the recommending agent MUST NOT auto-dispatch. See Section 1.3 for how `Recommended agents` are processed.

#### BLOCKED

Used when the agent cannot complete its task due to an unresolvable dependency, missing file, ambiguous requirement, or tool failure. A BLOCKED status causes `agent-status-reader.sh` to emit a `[CAST-HALT]` directive and exit with code 2, hard-blocking the parent session.

```
Status: BLOCKED
Summary: [one sentence describing what was attempted]
Blocker: [precise description of what is missing or failed — be specific enough to resolve]
```

Required fields: `Status`, `Summary`, `Blocker`
Optional fields: none

A BLOCKED agent MUST NOT silently fail or partially complete work. It MUST roll back any partial changes before emitting BLOCKED, or explicitly list changes made so the operator can clean up.

#### NEEDS_CONTEXT

Used when the agent needs additional information from the user or calling context before it can proceed. Unlike BLOCKED, the agent has not attempted the work — it paused to request clarification.

```
Status: NEEDS_CONTEXT
Summary: [one sentence describing what was attempted]
Missing: [specific questions or data needed to proceed]
```

Required fields: `Status`, `Summary`, `Missing`
Optional fields: none

The `/orchestrate` skill handles NEEDS_CONTEXT by pausing batch execution, surfacing the `Missing` field to the user, and re-dispatching the same agent with the updated context prepended to its prompt.

### 1.2 JSON File Format (machine-readable, required for code-modifying agents)

Agents that modify code MUST also write a JSON status file via `cast_write_status` (sourced from `~/.claude/scripts/status-writer.sh`). Agents that only read or report MAY skip this.

**File path:** `~/.claude/agent-status/<agent-name>-<timestamp>.json`

**Timestamp format:** `YYYYMMDDTHHMMSSz` (UTC, e.g., `20260324T153042Z`)

**Schema:**

```json
{
  "agent": "string — agent name matching its frontmatter name field",
  "status": "DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT",
  "summary": "string — mirrors the text Status Block Summary field",
  "concerns": "string | null — mirrors Concerns field; null when not applicable",
  "recommended_agents": "string | null — mirrors Recommended agents as comma-separated list or null",
  "timestamp": "string — YYYYMMDDTHHMMSSz UTC"
}
```

**Writing the file (bash helper):**

```bash
source ~/.claude/scripts/status-writer.sh
cast_write_status "DONE" "Implemented auth module" "code-writer" "" ""
cast_write_status "DONE_WITH_CONCERNS" "Implemented auth module" "code-writer" \
  "dead code remains in src/utils.js lines 45-67" "code-reviewer"
cast_write_status "BLOCKED" "Could not complete implementation" "code-writer" \
  "Missing test coverage — cannot verify behavior preservation" ""
```

**How `agent-status-reader.sh` processes the file:**

The `agent-status-reader.sh` PostToolUse hook (CAST v2 — **no longer registered in v3**; see §5.5, where status propagation moved to the model reading Status blocks directly) locates the latest JSON file in `~/.claude/agent-status/` by lexicographic sort of filenames (which encode UTC timestamp). It then:

| Status | Hook action | Exit code |
|---|---|---|
| `DONE` | Exit silently | 0 |
| `DONE_WITH_CONCERNS` | Output `[CAST-REVIEW]` directive via `hookSpecificOutput` | 0 |
| `BLOCKED` | Output `[CAST-HALT]` directive and block message | 2 |
| `NEEDS_CONTEXT` | Exit silently (main session reads text block) | 0 |
| File missing | Exit silently | 0 |

Path canonicalization: before reading any status file, `agent-status-reader.sh` calls `realpath` and verifies the result starts with `$HOME/`. Files outside `$HOME` are silently skipped.

### 1.3 code-reviewer Recommendations

When `code-reviewer` emits `DONE_WITH_CONCERNS`, the `Recommended agents:` subsection lists follow-up agents. Format:

```
Recommended agents:
  - code-writer: dead code in src/utils.js lines 45-67
  - security: potential auth bypass in src/auth/login.js line 112
  - docs: public API signature changed in src/api/routes.js
```

Rules:
- Each entry names one agent from the CAST registry
- Reason MUST reference a specific file and line number where possible
- `code-reviewer` MUST NOT dispatch these agents — it only recommends
- The main session reads the `Recommended agents:` section and decides whether to dispatch
- `code-reviewer` MUST NOT recommend another `code-reviewer` — this creates infinite loops
- Maximum 3 recommended agents per review pass

---

## Section 2 — Escape Hatch Pattern

CAST's unified `PreToolUse: Bash` gate, `cast-pretool-dispatch.py`, hard-blocks destructive Bash operations. It runs the git-guard (`pre-tool-guard.sh`'s rules: commit/push/stash + policy-protected writes) and the command-guard (`cast-command-guard.py`'s rules, loaded as a library: process mass-kills + `rm -rf` of protected roots) in every context, including `CLAUDE_SUBPROCESS=1` (headless/managed) — escape hatches, not subprocess status, are the only sanctioned bypass.

### 2.1 Defined Escape Hatches

| Escape hatch | Unblocked operation | Who uses it |
|---|---|---|
| `CAST_COMMIT_AGENT=1` | `git commit` | `commit` agent exclusively |
| `CAST_PUSH_OK=1` | `git push` | Post-review push workflows |
| `CAST_STASH_OK=1` | `git stash` (all variants) | Rare authorized stash use, documented in the agent |
| `CAST_KILL_OK=1` | `pkill`/`killall`/process-group kill | Rare authorized process-kill |
| `CAST_RM_OK=1` | `rm -rf` of a protected root/subtree | Rare authorized destructive delete |
| `CAST_POLICY_OVERRIDE=1` | Write/Edit to a policy-protected file | Human-authorized override (audit-logged) |

### 2.2 Syntax Requirements

The escape hatch MUST appear as a **leading environment variable assignment** immediately before the git command on the same command string. No other tokens may precede it.

**Valid:**
```bash
CAST_COMMIT_AGENT=1 git commit -m "feat(auth): add token refresh"
CAST_PUSH_OK=1 git push origin main
```

**Invalid — blocked:**
```bash
git commit -m "CAST_COMMIT_AGENT=1"          # message injection
echo "CAST_COMMIT_AGENT=1" && git commit     # chained echo
export CAST_COMMIT_AGENT=1; git commit       # separate export statement
```

### 2.3 Security Model

The hook uses the regex `^CAST_COMMIT_AGENT=1[[:space:]]+git[[:space:]]+commit` anchored at position 0 of the full command string. The anchor at `^` is not a performance optimization — it is the security boundary. A check using `grep -q "CAST_COMMIT_AGENT=1"` anywhere in the command would allow message injection attacks (e.g., a commit message that contains the bypass string to trick a future audit).

The same positional-anchor model applies to `CAST_PUSH_OK=1`.

### 2.4 Adding New Escape Hatches

To add a new escape hatch for a blocked operation:

1. Define the env var name in the format `CAST_<OPERATION>_<ACTOR>=1`
2. Add an allow-block in `pre-tool-guard.sh` anchored at `^` before the corresponding block rule
3. Document it in this table (Section 2.1)
4. The escape hatch MUST only be used by the designated agent — document that constraint in the agent's definition

Exit code semantics: exit 0 = allow, exit 2 = hard-block. Never use exit 1 in pre-tool-guard.sh.

### 2.5 Irreversibility Interrupt Ledger

CAST treats a defined set of operations as **irreversible or destructive** — they delete data, publish history, or kill processes in ways that cannot be cheaply undone. This ledger is the canonical list: what each op is, what gates it, and — the load-bearing column — **whether that gate still fires in an unattended auto-chain.**

**Three execution contexts, decreasing supervision** (this is *why* the last column matters):

| Context | `CLAUDE_SUBPROCESS` | PreToolUse hooks | `AskUserQuestion` |
|---|---|---|---|
| Interactive main session **and in-session Agent-tool subagents** (incl. a `planner`→`/orchestrate` chain) | unset | **fire** | prompts the user |
| Headless / managed sub-claude (`claude -p`, `cast-managed-agent.sh`) | `1` | **partial** — git-guard + command-guard destructive-op blocks (commit/push/stash, mass-kill, `rm -rf` of protected roots) still **fire**; Write/Edit-policy, egress recording, and dispatch-capture **skip** (`exit 0` on the `CLAUDE_SUBPROCESS` check) | auto-answered "safest default" (`cast-headless-guard.sh`) |
| Cron / launchd direct (`cast-db-prune.py`, `cast-migrate.py`) | n/a | **absent** — no Claude in the loop | n/a |

> Verified 2026-06-14: a native Agent-tool subagent runs with `CLAUDE_SUBPROCESS` **unset**, so the hook guards DO fire for it (a subagent's `pkill` is hard-blocked, exit 2). The "subagents run with `CLAUDE_SUBPROCESS=1`" notes elsewhere in this spec describe the older headless/managed dispatch model, not native Agent-tool subagents.

**Design rule — auto-chain safety:** the git-guard and command-guard hard-blocks (commit/push/stash; process mass-kill; `rm -rf` of protected roots) fire **unconditionally** — before the `CLAUDE_SUBPROCESS` early-return in `cast-pretool-dispatch.py` — so they protect both the interactive context (row 1) **and** headless/managed (row 2). It's the **Write/Edit-policy engine, egress recording, and dispatch-capture** (plus confirm-pauses, which aren't hooks at all) that are **bypassed** in headless/managed (row 2); those, and every hook-based gate, are absent in cron/launchd (row 3). An irreversible op outside the git-guard/command-guard umbrella is **auto-chain-safe only if it is protected by a fail-closed script-level gate** (back-up-or-abort inside the script itself) **or an agent text-refusal.** New destructive automation MUST carry its own fail-closed gate rather than relying on a hook.

**The ledger:**

| Op class | Operation(s) | Enforced by | Type | Escape hatch | Auto-chain-safe? |
|---|---|---|---|---|---|
| Git commit | raw `git commit` | `pre-tool-guard.sh` (commit block) + provenance recording (`cast-commit-provenance.py record`) + pre-push reconcile (`cast-commit-reconcile.py`) | hard-block + audit trail | `CAST_COMMIT_AGENT=1` (records provenance); `CAST_RECONCILE_ACK=1` (human-approved exception) | ✓ hook (unconditional) |
| Git push | raw `git push` | `pre-tool-guard.sh` (push block) | hard-block | `CAST_PUSH_OK=1` | ✓ hook (unconditional) |
| Force-push | `git push --force` | `push.md` (agent refusal) | refuse | none | ◑ agent-refusal |
| Push to main (work repo) | push to `main`/`master` | `push.md` (branch rule) | refuse | `--force-main` / `repo_class=personal` | ◑ agent-refusal |
| PR merge | squash-merge; force-merge to main | `merge.md` (confirm / hard-block) | confirm / hard-block | text confirmation | ◑ agent-only |
| Git stash | all `git stash` variants | `pre-tool-guard.sh` (stash block) | hard-block | `CAST_STASH_OK=1` | ✓ hook (unconditional) |
| Working-tree reset | `git reset --hard`/`--merge`/`--keep` (flag before or after ref) | `cast-git-guard.py` (reset block) | hard-block | `CAST_RESET_OK=1` | ✓ hook (unconditional) |
| Untracked-file clean | `git clean` (any form except `-n`/`--dry-run`) | `cast-git-guard.py` (clean block) | hard-block | `CAST_CLEAN_OK=1` | ✓ hook (unconditional) |
| Worktree checkout | `git checkout -- <pathspec>` / `git checkout .` / bare `git checkout <existing-path>` (no `--`) / `git checkout -f`/`--force` (plain branch ops unaffected) | `cast-git-guard.py` (checkout block) | hard-block | `CAST_CHECKOUT_OK=1` | ✓ hook (unconditional, but the bare-path form is a cwd-dependent filesystem check — see 2026-08-17 3rd follow-up note) |
| Worktree restore | `git restore` except `--staged` without `--worktree` | `cast-git-guard.py` (restore block) | hard-block | `CAST_RESTORE_OK=1` | ✓ hook (unconditional) |
| Worktree switch | `git switch -f`/`--force`/`--discard-changes` (plain `git switch <branch>` unaffected — not destructive by default) | `cast-git-guard.py` (switch block) | hard-block | `CAST_SWITCH_OK=1` | ✓ hook (unconditional) |
| Reflog destruction | `git reflog expire`/`git reflog delete` (plain `git reflog`/`show`/`exists` unaffected) | `cast-git-guard.py` (reflog block) | hard-block | `CAST_REFLOG_OK=1` | ✓ hook (unconditional) |
| Object pruning (gc) | `git gc --prune=<value>` (any explicit value; bare `git gc`/`--aggressive`/`--prune` no-value/`--no-prune`/`--auto` unaffected) | `cast-git-guard.py` (gc block) | hard-block | `CAST_GC_OK=1` | ✓ hook (unconditional, but bare `git gc` stays unenforced — see note below) |
| Object pruning (prune) | `git prune` in any non-dry-run form (`-n`/`--dry-run` unaffected; `git prune-packed`/`git remote prune`/`git worktree prune` are distinct commands, also unaffected) | `cast-git-guard.py` (prune block) | hard-block | `CAST_PRUNE_OK=1` | ✓ hook (unconditional) |
| GC config injection | `git -c gc.pruneExpire=<v>` / `-c gc.reflogExpire=<v>` / `-c gc.reflogExpireUnreachable=<v>` on ANY subcommand, any value, case-insensitive key | `cast-git-guard.py` (gc-cinject block) | hard-block | `CAST_GC_OK=1` (shared, no new hatch) | ✓ hook (unconditional, but `--config-env=`/`GIT_CONFIG_*` env-var indirection stays unenforced — see note below) |
| GC config write | `git config` write (any form) of `gc.pruneExpire`/`gc.reflogExpire`/`gc.reflogExpireUnreachable`, case-insensitive key (reads via `--get`/bare-key unaffected) | `cast-git-guard.py` (gc config-write block) | hard-block | `CAST_GC_OK=1` (shared, no new hatch) | ✓ hook (unconditional) |
| Force file removal | `git rm -f`/`--force` (incl. clustered `-rf`/`-fr`/`-rfq`); index-only `--cached` and `-n`/`--dry-run` forms unaffected | `cast-git-guard.py` (git-rm block) | hard-block | `CAST_GIT_RM_OK=1` | ✓ hook (unconditional) |
| Branch force-delete | `git branch -D` (incl. clusters, e.g. `-qD`), `--delete --force`, `-d … --force` (either order); `-d` alone, `-m`, `-c`, and read-only forms unaffected | `cast-git-guard.py` (branch block) | hard-block | `CAST_BRANCH_OK=1` | ✓ hook (unconditional) |
| Worktree force-removal | `git worktree remove -f`/`--force`; bare `remove` (git itself refuses on a dirty or untracked-bearing tree), `add -f`, `list`, `prune` unaffected | `cast-git-guard.py` (worktree block) | hard-block | `CAST_WORKTREE_OK=1` | ✓ hook (unconditional) |
| Ref deletion | `git update-ref -d`, plus `--stdin` denied by default (its payload is invisible to a command-line scanner); create/update argument forms unaffected | `cast-git-guard.py` (update-ref block) | hard-block | `CAST_UPDATE_REF_OK=1` | ✓ hook (unconditional) |
| History rewrite | `git filter-branch` (any form) | `cast-git-guard.py` (filter-branch block) | hard-block | `CAST_FILTER_BRANCH_OK=1` | ✓ hook (unconditional) |
| Schema migration | destructive DDL/DML via `cast-migrate.py` | `cast-migrate.py` (`_pre_migration_backup`) | **fail-closed backup** | none | ✓ **script gate** |
| DB row prune | nightly `DELETE` of old rows | `cast-db-prune.py` (`_pre_prune_backup`) | **fail-closed backup** | none | ✓ **script gate** |
| Process mass-kill | `pkill`/`killall`/`kill -1`/`kill 0` | `cast-command-guard.py` (kill rule) | hard-block | `CAST_KILL_OK=1` | ✓ hook (unconditional) |
| Destructive delete | `rm -rf`/rmtree of protected roots | `cast-command-guard.py` (rm rule) + `cast_guard.safe_rmtree` + `blast-radius-lint.sh` | hard-block + scoped lib + CI lint | `CAST_RM_OK=1` | ✓ hook (unconditional) + lib + lint |
| Risky write | literal-`~` path, policy-protected file, badge mismatch | `write-guards.py` + `pre-tool-guard.sh` (policy rule) | hard-block | `CAST_POLICY_OVERRIDE=1` (audited) | ✗ hook-only |
| Orchestration pause | batch interrupt window; freeze/careful mode | `skills/orchestrate`, `skills/freeze-mode` | confirm-pause | abort / deactivate | ✗ confirm-only |

Legend: **✓** survives an unattended auto-chain · **◑** survives only via its non-hook layer (agent refusal, guard-lib, or CI lint) · **✗** interactive-context only (bypassed headless, absent in cron).

**Notes / gaps (2026-06-14):**
- The two recurring **DB destructive paths now both fail-closed-back-up** (migration `_pre_migration_backup`; nightly prune `_pre_prune_backup`). `cast-db-prune.py` runs via `launchd` (`com.cast.db-prune`, 03:30) with no Claude in the loop, so its script-level gate is the *only* protection that can apply — the row-3 case made concrete.
- `cast-memory-consolidate.py` dedup deletes are recoverable only on the low-importance path (archives to `archived_memories` first); the dedup-of-duplicates path hard-deletes (manual-only, low risk — deferred).
- Hook-based interrupts split in two: the git-guard/command-guard hard-blocks are **auto-chain guarantees** (they fire unconditionally, headless/managed included); the Write/Edit-policy engine, egress recording, dispatch-capture, and confirm-pauses are **interactive-context guarantees only** — skipped in headless/managed and absent in cron (by design, to prevent hook recursion). That asymmetry is the reason the design rule above distinguishes the two.
- **2026-08-17:** a dispatched `commit` agent ran a raw `git reset --hard` + `git clean`, destroying a fully reviewed, gated working-tree diff (recovered only via a dangling-blob hunt). `cast-git-guard.py` and `cast-command-guard.py` had **zero** enforcement on `reset`/`clean` — while `commit`/`push`/`stash` (the recoverable-or-non-destructive ops) were all hard-blocked. Closed by adding the two rows above: `reset --hard`/`--merge`/`--keep` and non-dry-run `clean` now hard-block unconditionally, same as commit/push/stash; bare `reset` and `reset --soft`/`--mixed` (index-only, routine) stay unblocked to avoid false positives.
- **Same 2026-08-17 pass, same defect class:** a probe found `git checkout -- .`/`git checkout .` and `git restore` also unenforced — the exact mechanism a READ-ONLY `code-reviewer` used to silently revert the file it was reviewing (a documented, already-realized incident; see the CLAUDE.md reviewer-revert note). Closed by the two rows above. `git checkout` cannot decide "pathspec vs. branch name" in general, so the block keys only on the `--` separator and a literal `.` argument — plain branch ops (`checkout <branch>`, `-b`, `-`, `--track`) stay unblocked. `git restore` blocks unless `--staged` is present without `--worktree` (index-only unstage). Deliberately **out of scope** for this pass (surfaced, not fixed): `git branch -D`, `git worktree remove`, `git update-ref -d`, `git filter-branch`, and especially `git reflog expire --expire=now --all` / `git gc --prune=now` — that pair would have destroyed the dangling-blob recovery that saved the 2026-08-17 diff in the first place.
- **Same 2026-08-17 pass, two follow-up security-review rounds:** (1) per-LINE evaluation let ANY matched hatch void every later BLOCK on that line, across ops — `CAST_COMMIT_AGENT=1 git commit -m x && git push --force` was allowed at HEAD, pre-existing and not introduced by the additions above; fixed by evaluating each op independently rather than short-circuiting on first ALLOW. (2) a same-op variant of the identical class survived that fix: a hatch on a HARMLESS invocation of an op (e.g. `git reset --soft`) still unlocked a DESTRUCTIVE invocation of the *same* op later on the line (`CAST_RESET_OK=1 git reset --soft && git reset --hard`) — also pre-existing for commit (`CAST_COMMIT_AGENT=1 git commit --dry-run && git commit -m x` was allowed at HEAD). Fixed by evaluating per SHELL SEGMENT (split on `;`/`&&`/`||`/`|`) rather than per line, mirroring real shell env-prefix scoping. Net result: every destructive git command on a chained line now needs its own hatch immediately before it, for both cross-op and same-op chains. Residual, unaudited: only commit/push write an audit-log hatch-use event (`_audit_commit_hatch`/`_audit_push_hatch`); stash/reset/clean/checkout/restore hatches are enforced but leave no audit trail (surfaced, not fixed, this pass).
- **Same 2026-08-17 pass, third follow-up security-review round:** the stash/reset/checkout BLOCK regexes anchored "end of destructive token" on a LITERAL trailing `(\s|$)`, which adjacent empty-output command substitution defeats — the shell collapses `` git reset --hard$(true) `` to a real `git reset --hard`, but the regex never sees the trailing whitespace it requires, so it was **allowed with no hatch and no audit trail** (also reproduced for `--merge`/`--keep`, `` git checkout .$(true) ``, and `` git stash`true` ``). Closed by anchoring on the token boundary instead: `\b` for the word-ending flags (`--hard`/`--merge`/`--keep`/`stash`), and an equivalent negative-lookahead for the bare-`.` checkout case (`.` is itself a non-word character, so `\b` does not fire between it and an adjacent non-word shell metacharacter like `$` — the lookahead instead rejects only `.` immediately followed by a word char, `.`, `/`, or `-`, so `.github`/`./foo` stay unmatched). Confirmed NOT vulnerable to this evasion (deny-by-default shape): `git clean -fd$(true)`, `git restore .$(true)`, `git push$(true)`, `git commit -m x$(true)`. This is orthogonal to the subshell/command-substitution-*wrapping* gap noted in the module docstring (`$(git reset --hard)`, `(git reset --hard)`) — that gap hides the whole `git` invocation and remains out of scope; this fix only closes the case where the destructive git invocation is plainly on the line with an adjacent, empty-output substitution appended.
- **Same 2026-08-17 pass, fourth follow-up security-review round (blocker):** the checkout row above previously blocked only the `--`-separator and bare-`.` forms — `git checkout <bare-path>` with NEITHER (e.g. `` git checkout completions/cast.bash ``) was still ALLOWED, and that bare form is the EXACT command the 2026-08-15 code-reviewer incident used (see `~/.claude/rules/working-conventions.md` Review Gate note: *"one silently reverted the file it reviewed... `completions/cast.bash` back at HEAD"*). Path-vs-branch is not shape-decidable by regex (`release/1.0.0` is a valid branch that looks exactly like a path), so this is NOT a regex fix: `_checkout_bare_path_blocks()` mirrors git's own disambiguation by treating a bare (non-flag, non-`.`) first token as a pathspec — and blocking it — only if `os.path.exists()` finds it relative to the guard's own cwd (or the segment's `-C <dir>`, if present). Verified allowed (branch-op forms, unaffected): `checkout <branch>`, `-b`, `-`, `--track`, `--detach`, `-B <branch> <start-point>`, ref forms (`HEAD~1`, `@{-1}`), and any bare token that doesn't resolve to a real path (e.g. `release/1.0.0` when no such path exists locally). Verified now blocked: `git checkout completions/cast.bash`, `git checkout f.txt` (fixture files that exist). **Known limitation, stated plainly, not glossed over:** this check is CWD-DEPENDENT — it has no visibility into a `cd` earlier in an unexecuted shell chain, or a cwd differing from git's actual working tree, so a branch name colliding with a real path elsewhere (but not relative to this cwd) is MISSED, not blocked. Advisory-grade, consistent with every other check in this module — not a proof.
- **Same 2026-08-17 pass, fifth follow-up security-review round (final, ship-gating):** two additions, both measured unguarded before this pass. (1) `git checkout -f`/`--force` — proceeds even when the working tree differs from HEAD, discarding local changes (e.g. `git checkout -f main`); unlike the bare-pathspec case, `-f`/`--force` is a flag, not a pathspec, so it IS regex-decidable and blocks on a lookahead for the literal token anywhere on the invocation (`git checkout -f -b new` still blocks on the `-f`). (2) `git switch`, the modern branch-changing half of `checkout`, was **completely unguarded** — `git switch --discard-changes main` and `git switch -f main` were both allowed. Added as a new op with its own hatch (`CAST_SWITCH_OK=1`, matching the one-hatch-per-command-name convention). Critically, `switch` is NOT symmetric with `checkout`: plain `git switch <branch>` is left UNBLOCKED because git itself refuses it when there are conflicting local changes — it isn't destructive by default the way bare `checkout <path>` is — so only the explicit `-f`/`--force`/`--discard-changes` forms block, and `switch` gets no filesystem/pathspec heuristic (it doesn't take pathspecs). Verified allowed: `switch <branch>`, `-c <new-branch>`, `-`, `--detach`; `checkout -b`, `-B <b> <start>`, `--track`, `--detach`, `-`, `<branch>`. Verified now blocked: `checkout -f main`, `checkout --force main`, `switch -f main`, `switch --discard-changes main`. **Explicitly deferred, not fixed this pass** (measured unguarded, scoped to a separate enumerated unit): `git rm -f`, `git rm -r --cached`, `git branch -D`, `git worktree remove -f`, `git update-ref -d`, `git filter-branch`, `git sparse-checkout set`, `git reflog expire --expire=now --all` + `git gc --prune=now`. **Concern recorded, not changed:** `_checkout_bare_path_blocks()` (added in the fourth follow-up above) fails OPEN on any internal error — a bug in that heuristic silently disables the check rather than blocking, which is defensible under "never crash the hook pipeline" but is worth knowing plainly rather than assuming fail-closed.
- **Same 2026-08-17 pass, sixth follow-up security-review round (completion of the fifth, LAST change to this unit):** the `-f`/`--force` regex added above only matched a STANDALONE `-f` token, missing git's own clustered short-flag syntax — `git checkout -fb newbranch` is valid git, parsed as `-f -b newbranch` (confirmed: `git checkout -fb` alone errors with `` switch `b' requires a value ``, proving git reads it flag-by-flag), fully destructive (force + branch-create), and was still ALLOWED. Same defect class already fixed once in this file for `_CLEAN_DRY_RUN` clustering (`-nd`/`-fn`); same fix shape applied via a shared `_FORCE_FLAG_LOOKAHEAD` fragment (`-[a-zA-Z]*f[a-zA-Z]*`, single-dash-anchored so `--force`/`--detach`/`--track` — which start with a second `-` — are unaffected), reused by both the checkout and switch force checks. Verified now blocked: `checkout -fb newbranch`, `checkout -bf newbranch` (reversed order), `switch -fc new`. Verified still allowed (the false-positive risk — clusters without `f`): `checkout -b`, `-B <b> <start>`, `-q`, `-t`, `-p`, `-m`; `switch -c`, `-`, `--detach`. Full suite 154/154 (was 144, +10). This closes the unit — no further additions to `cast-git-guard.py` are scoped for this pass.
- **2026-08-17 recovery-path pass (new unit, closes the reflog/gc/prune deferral from the fifth follow-up above):** measured against a throwaway repo (git 2.55.0) containing both recovery-path artifacts — an unreachable loose blob (the staged-then-lost content class) and a lost commit still held by the reflog. `git gc --prune=<value>` (ANY explicit value — `now`, `all`, or even `1.hour.ago` against a 3-hour-old blob) deleted the dangling blob but left the lost commit and all 3 reflog entries intact; bare `git gc`, `--aggressive`, `--prune` with no value, `--no-prune`, and `--auto` left everything intact. `git reflog expire --expire=now --all` zeroed the reflog (0 of 3 entries survived) without touching either object; `--expire-unreachable=now --all` left 1; `git reflog delete HEAD@{0}` left 2 — the object layer was untouched by all three reflog forms. A finding NOT on the original deferred list: bare `git prune` (no flags at all) also deleted the dangling blob, with no grace period whatsoever — measured MORE destructive than `git gc --prune=now`, since bare `gc` still honors `gc.pruneExpire` (default 2 weeks) while `prune`'s own default expiry is effectively immediate for a loose object with no reachable ref. Chaining `git reflog expire --expire=now --all && git gc --prune=now` destroyed both the reflog and the lost commit together. Three new ops now hard-block: `git reflog expire`/`git reflog delete` (`CAST_REFLOG_OK=1`), `git gc --prune=<value>` (`CAST_GC_OK=1`), and `git prune` in any non-dry-run form (`CAST_PRUNE_OK=1`) — see the three new ledger rows above. Same per-segment hatch scoping and cross-op independence as every other op in this ledger (`CAST_GC_OK=1 git gc --prune=now && git prune` still BLOCKS; each op needs its own hatch on its own segment). **Remaining deferred, unchanged by this pass** (still measured unguarded, still out of scope): `git rm -f`, `git rm -r --cached`, `git branch -D`, `git worktree remove -f`, `git update-ref -d`, `git filter-branch`, `git sparse-checkout set`. **Named gap, not closed by this pass:** bare `git gc` and `git gc --prune` (no value) stay unblocked and can still delete objects older than `gc.pruneExpire` (default 2 weeks) — a repo-local `gc.pruneExpire=now` config makes bare `git gc` as destructive as `--prune=now` with no flag on the command line for a regex layer to key on.
- **Same 2026-08-17 pass, same-day follow-up (config-route bypass):** the named gap above understated the risk — it isn't just "bare `git gc` could be destructive if `gc.pruneExpire` were already `now`," it's a complete, single-command bypass of every block in the prior paragraph. Measured (same throwaway-repo fixture, git 2.55.0) **four routes** to setting an expiry config value: (1) `git -c gc.pruneExpire=now gc` (inline injection) — blob GONE; (2) `git config gc.pruneExpire now && git gc` (persistent write then bare gc) — blob GONE; (3) `git --config-env=gc.pruneExpire=PRX gc` with `PRX=now` in the environment — blob GONE; (4) `GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=gc.pruneExpire GIT_CONFIG_VALUE_0=now git gc` — blob GONE. `-c gc.reflogExpire=now -c gc.pruneExpire=now gc` combines the reflog and prune destruction into ONE command with no `expire`/`prune`/`--prune=` token on the line at all — the exact total destruction of the 2026-08-17 incident's `reflog expire --all && gc --prune=now`, reachable with nothing any prior block in this ledger keys on. Routes (1) and (2) are now hard-blocked, under the EXISTING `CAST_GC_OK=1` hatch (no new hatch) — see the two new ledger rows above. Routes (3) and (4) are measured, confirmed still open, and deliberately documented rather than chased — same family as the subshell/`$( )` and quoted-token limitations already in the module docstring: the value/key never appears as a literal `-c key=value` or `config key value` token on the scanned line, so closing them would need real shell+env tokenization, not more regex. One more finding recorded honestly rather than glossed over: whether inline expiry config combined with git's own auto-gc (any subcommand that can trigger it, not just `gc`) is ITSELF destructive at scale is **UNRESOLVED** — a first probe read as "harmless" but that probe only checked object survival while `gc.autoDetach` (default TRUE) may have simply raced a backgrounded gc; a corrected probe (`gc.autoDetach=false`, counting loose objects directly) showed auto-gc never fired at all in a 7-object repo, because that's too small to trip the default threshold — so the honest statement is "could not be made to fire in a repo small enough to probe cheaply," not "verified harmless." This is why route (1)'s block is NOT narrowed to the `gc` subcommand: narrowing it would require answering that open question first.
- **2026-08-17 remaining-ops pass (closes the last deferral from the fifth follow-up round and the recovery-path pass):** all seven still-deferred ops were measured against throwaway repos on git 2.55.0 *before* any pattern was written, and **two of the seven measured NON-destructive and are deliberately NOT blocked.** (a) `git rm -r --cached <dir>` left the worktree file in place **with its uncommitted edit intact** — it drops only the index entry, recoverable with `git reset`. (b) `git sparse-checkout set <dir>` removes only files whose content is already committed: git **refuses** to remove a locally-modified file (`warning: The following paths are not up to date and were left despite sparse patterns`), leaves untracked files alone, and `add`/`disable` restore what `set` removed. Regression fences in `tests/pre-tool-guard.bats` assert both stay ALLOW, so a later pass cannot quietly start blocking them without failing a test. Two corrections to the original deferred list: `git update-ref --delete` is **not a valid git flag** (measured rc=129 — only `-d` works), so its absence from the block is deliberate rather than an omission; and `git sparse-checkout init --cone` removes *more* than `set` does (every non-root path) yet was never on the list at all. The remaining five now hard-block — see the five new rows above. **Security-review finding, found and fixed inside this same pass:** the `git rm` block's `--cached` exemption first used a bare `\b`, so any pathspec merely *starting with* `--cached` (e.g. `git rm -f -- --cached-evil.txt`) satisfied the negative lookahead and disabled the entire block — a complete, single-command bypass of a brand-new hard-block, and the same defect class this file had already fixed twice (`prune(?![\w-])` against `prune-packed`, `filter-branch(?![\w-])`). Now token-anchored as `(?!.*(?:^|\s)--cached(?:\s|$))`, with four regression tests and a mutation test confirming they fail against the old pattern. **Residual, stated plainly:** a file literally *named* `--cached` passed after a `--` separator still reads as the flag and is exempted; a command-line scanner cannot distinguish the two. **Newly surfaced, measured unguarded, NOT closed by this pass:** `git branch -M <src> <dst>` clobbers an existing destination branch (measured — the victim's tip became unreachable); `git branch -f <branch> <sha>` force-moves a branch pointer (its reflog survives, so it is recoverable); and the non-delete `git update-ref <ref> <sha>` likewise rewrites a ref. **Named gap, module-wide and PRE-EXISTING — verified at `a77ffb6`, i.e. before this pass: `_GIT_OPTS` matches `-C\s+\S+`, so a `-C` path containing a space defeats EVERY op in this ledger.** `git -C '/tmp/my dir' commit -m x`, the same with `reset --hard`, with `push`, and with `clean -fdx` were all measured ALLOW both at HEAD and after this pass. Closing it means changing the shared `_GIT_OPTS` fragment that every guarded op depends on, so it is scoped to its own unit with its own review rather than folded in here.

---

## Section 3 — Agent Dispatch Manifest Format

An Agent Dispatch Manifest is a declarative execution plan embedded in a plan `.md` file under `~/.claude/plans/`. It tells the `/orchestrate` skill which specialist agents to run, in what order, and whether they can run in parallel.

### 3.1 Location and Detection

A manifest lives inside a `## Agent Dispatch Manifest` section in a plan file. The manifest itself is a fenced code block tagged `json dispatch`:

````markdown
## Agent Dispatch Manifest

```json dispatch
{ ... }
```
````

> **Phase 10 convergence:** The Agent Dispatch Manifest JSON is the CAST *legacy* orchestration path. Native Dynamic Workflows (the Workflow tool, available & verified 2026-06-03) are the convergence target; the ADM path is retained as the stable fallback until a piloted migration. See `~/.claude/research/2026-06-03-anthropic-devs-claude-code-convergence.md` Phase 10.

When `post-tool-hook.sh` sees a `Write` tool call to a `.md` file under a `/plans/` path that contains a `json dispatch` block, it injects a `[CAST-ORCHESTRATE]` directive telling Claude to invoke the `/orchestrate` skill with the plan file path.

### 3.2 Full Field Reference

```json
{
  "batches": [
    {
      "id": 1,
      "description": "Human-readable label shown in the dispatch queue",
      "parallel": true,
      "type": "fan-out",
      "agents": [
        {
          "subagent_type": "planner",
          "prompt": "Create a detailed implementation plan for X. Plan file: ~/.claude/plans/2026-03-24-X.md"
        },
        {
          "subagent_type": "security",
          "prompt": "Audit the security surface of X before implementation."
        }
      ]
    },
    {
      "id": 2,
      "description": "Implementation",
      "parallel": false,
      "agents": [
        {
          "subagent_type": "main",
          "prompt": "Implement X per the plan at ~/.claude/plans/2026-03-24-X.md"
        }
      ]
    },
    {
      "id": 3,
      "description": "Code-quality review",
      "parallel": false,
      "agents": [
        {
          "subagent_type": "code-reviewer",
          "prompt": "Review the changes just made for X"
        }
      ]
    },
    {
      "id": 4,
      "description": "Test run (own batch — never co-scheduled with a review agent; test-runner's suite-timeout/kill path can reap a sibling process)",
      "parallel": false,
      "agents": [
        {
          "subagent_type": "test-runner",
          "prompt": "Run tests to verify the new logic added in X"
        }
      ]
    },
    {
      "id": 5,
      "description": "Commit",
      "parallel": false,
      "agents": [
        {
          "subagent_type": "commit",
          "prompt": "Create a semantic commit for the completed X work."
        }
      ]
    }
  ]
}
```

### 3.3 Field Definitions

| Field | Type | Required | Description |
|---|---|---|---|
| `batches` | array | yes | Ordered list of execution batches |
| `id` | integer | yes | Monotonically increasing batch number; used in task board keys |
| `description` | string | yes | Human-readable label for the dispatch queue display |
| `parallel` | boolean | yes | `true` = dispatch all agents in batch simultaneously; `false` = dispatch one agent, wait for completion |
| `type` | string | no | `"fan-out"` enables Fan-out Dispatch behavior (see Section 7); `"sequential"` is the default when omitted |
| `agents` | array | yes | One or more agent dispatch entries |
| `subagent_type` | string | yes | Name of the agent to dispatch, matching the `name` field in the agent's frontmatter; or `"main"` for main session inline execution |
| `prompt` | string | yes | Task description passed to the agent; MUST be specific and include relevant context (feature name, file paths, plan path) |

### 3.4 `"parallel": true` Fan-out Behavior

When `"parallel": true`, the /orchestrate skill dispatches all agents in the batch in a single response using simultaneous Agent tool calls. Agents in a parallel batch MUST NOT depend on each other's outputs. Maximum 4 agents per parallel batch. A parallel batch MUST NOT co-schedule `test-runner` (or any process-killing / test-executing agent) with a review agent (`code-reviewer`, `security`, `frontend-qa`) — `test-runner`'s suite-timeout/kill path can reap co-scheduled sibling processes (observed 2026-06-14). Give `test-runner` its own sequential batch.

### 3.5 `"type": "sequential"` vs `"type": "fan-out"`

- `"type": "sequential"` (default): agents run one at a time regardless of `parallel` flag; the `parallel` flag takes precedence if set to `true`
- `"type": "fan-out"`: all agents dispatch simultaneously AND the /orchestrate skill synthesizes their outputs before passing context to the next batch (see Section 7)

### 3.6 `"subagent_type": "main"` Semantics

When `subagent_type` is `"main"`, the /orchestrate skill does not spawn a subagent via the Agent tool. Instead, the main session executes the implementation instructions directly. This is used for batches where the work cannot be effectively delegated, such as complex multi-file implementation steps that require the full reasoning context of the session.

### 3.7 Retry Protocol

When a batch returns `Status: BLOCKED`, the /orchestrate skill applies the following retry protocol:

1. Log the BLOCKED status to the task board with the blocker description
2. Re-dispatch the same batch a second time, prepending: `"Previous attempt BLOCKED: <blocker>. Resolve and retry."` to the agent prompt
3. If the second attempt also returns BLOCKED: re-dispatch one final time with the full accumulated context from both prior attempts
4. If the third attempt returns BLOCKED: halt execution and surface to the user: `"Batch <id> blocked after 3 attempts. Human intervention required. Blocker: <blocker>"` — do not proceed to subsequent batches
5. If any retry succeeds (DONE or DONE_WITH_CONCERNS): resume normal execution from the next batch

Maximum retries: 3 total attempts (1 original + 2 retries). The retry limit exists to prevent runaway loops in cases where the blocker is systemic.

### 3.8 Minimum Valid Manifest

The minimum CAST-compatible manifest is:

```json
{
  "batches": [
    {"id": 1, "description": "Implementation", "parallel": false, "agents": [{"subagent_type": "main", "prompt": "..."}]},
    {"id": 2, "description": "Review", "parallel": false, "agents": [{"subagent_type": "code-reviewer", "prompt": "..."}]},
    {"id": 3, "description": "Commit", "parallel": false, "agents": [{"subagent_type": "commit", "prompt": "..."}]}
  ]
}
```

---

## Section 4 — Dispatch Directive Protocol

Dispatch directives are injected into Claude's context by hook scripts via `hookSpecificOutput`. They are MANDATORY instructions — not suggestions. Claude MUST act on them immediately.

### 4.1 `[CAST-DISPATCH]`

**Format injected by hook:**
```
[CAST-DISPATCH] Route: <agent> (confidence: hard|soft)
MANDATORY|RECOMMENDED: Dispatch the `<agent>` agent via the Agent tool (model: <model>).
Pass the user's full prompt as the agent task. Do NOT handle this inline.
```

**Trigger:** In CAST v3, `[CAST-DISPATCH]` is no longer injected by a hook. The model reads the dispatch table in `CLAUDE.md` and dispatches agents directly via the Agent tool. This directive is documented here for protocol reference but is now handled by model-driven dispatch rather than hook injection.

**What Claude must do:** Dispatch the named agent via the Agent tool immediately. Do not answer the user's question inline. Do not ask for confirmation when confidence is `hard`.

**Confidence levels:**
- `hard` — dispatch is MANDATORY; Claude may not handle inline
- `soft` — dispatch is RECOMMENDED; Claude may use judgment but should prefer the agent

**Consequences if ignored:** The work bypasses the specialist agent's quality checks, producing lower-quality output and breaking chain/review guarantees.

### 4.2 `[CAST-REVIEW]`

**Format injected by hook:**
```
[CAST-REVIEW] Code was modified. After completing your current logical unit of changes,
dispatch `code-reviewer` agent (haiku) to review. Do not skip this step.
```

**Trigger:** `post-tool-hook.sh` (PostToolUse hook) fires after any Write or Edit tool call in the main session

**What Claude must do:** After completing the current logical unit of changes (not after every single file edit), dispatch `code-reviewer` (haiku model) via the Agent tool.

**CLAUDE_SUBPROCESS guard:** This directive is only injected in the main session (`CLAUDE_SUBPROCESS != 1`). Subagents do not receive it — they have their own internal review logic or report status to the main session.

**Agents that self-dispatch code-reviewer:** `backend-writer`, `frontend-writer`, and `debugger` self-dispatch `code-reviewer` internally. The main session MUST NOT re-dispatch `code-reviewer` after these agents complete — the review already happened internally.

### 4.3 `[CAST-CHAIN]`

**Format injected by hook:**
```
[CAST-CHAIN] After <agent> completes: dispatch `agent-a` -> `agent-b` in sequence.
```

**Trigger:** In CAST v3, post-chain behavior is defined in `CLAUDE.md` (not injected by hooks). After backend-writer or frontend-writer or debugger completes: `code-reviewer → commit → push`. The model reads this protocol and dispatches accordingly.

**What Claude must do:** After the primary agent's task is complete, dispatch the listed agents in order. Do not ask for confirmation. Each agent in the chain receives the output of the previous agent as context.

**Consequences if ignored:** Quality gates (code-reviewer) and commit steps (commit agent) are skipped, leaving code unreviewed and uncommitted.

### 4.4 `[CAST-ORCHESTRATE]`

**Format injected by hook:**
```
[CAST-ORCHESTRATE] Plan file at <path> contains an Agent Dispatch Manifest.
Invoke the `/orchestrate` skill with this plan file path.
Present the queue to the user for approval before executing any batches.
```

**Trigger:** `post-tool-hook.sh` detects a `json dispatch` block in a newly written `.md` file under a `/plans/` path

**What Claude must do:** Invoke the `/orchestrate` skill with the plan file path. The skill presents the queue to the user for approval before executing any batches. Plan execution runs in the main session — do not dispatch a separate orchestrator subagent.

### 4.5 `[CAST-HALT]`

**Format injected by hook:**
```
**[CAST-HALT]** Agent `<agent>` is BLOCKED and cannot proceed.
Summary: <summary>
Concerns: <concerns>
Resolve the blocker before continuing. Do not retry the blocked operation.
```

**Trigger:** `agent-status-reader.sh` reads a status JSON file with `"status": "BLOCKED"` and exits with code 2

**What Claude must do:** Surface the blocker description to the user immediately. Do not retry the blocked operation. Do not proceed to any subsequent steps. Wait for the user to resolve the blocker or provide missing context.

**Exit code 2 semantics:** Claude Code treats exit 2 from a hook as a hard block — Claude cannot proceed with the current operation. This is the only CAST directive enforced at the tool level rather than the instruction level.

---

### 4.6 `[CAST-DISPATCH-GROUP]`

> **Historical (CAST v2):** This directive was removed in CAST v3. Agent groups and the routing table were eliminated in favor of model-driven dispatch.

> **Phase 10:** `[CAST-DISPATCH-GROUP]` is a legacy directive; native Dynamic Workflows are the convergence target.

`[CAST-DISPATCH-GROUP]` auto-generates an Agent Dispatch Manifest from the Payload JSON in the directive. The main session invokes the `/orchestrate` skill immediately with the plan file path. The main session executes waves in order: parallel agents fire simultaneously, a Fan-out Summary is prepended to the next wave's prompts, and post_chain agents run sequentially after all waves complete. Wave-based dispatch follows the same fan-out semantics defined in Section 3.4, with agents in each wave running in parallel before the next wave begins.

---

## Section 5 — Hook Event Model

CAST uses three Claude Code hook events. Each hook script reads a JSON payload from stdin and outputs either nothing (allow silently) or a JSON response to stdout.

### 5.1 Hook Overview

| Event | Hook script | Fires when |
|---|---|---|
| `PreToolUse:Bash` | `pre-tool-guard.sh` | Claude is about to run a bash command |
| `PostToolUse:Write\|Edit` | `post-tool-hook.sh` | Claude just wrote or edited a file |
| `PostToolUse:Agent` | `cast-cost-tracker.sh` | Claude just dispatched an agent |
| `Stop` | `cast-session-end.sh` | Session ends |
| `SubagentStop` | `cast-subagent-stop-hook.sh` + `cast_subagent_stop.py` | A subagent has finished — updates agent_runs, detects truncation/completeness/protocol violations, records incidents, emits budget alerts, and compresses hookSpecificOutput; single python process, no sub-hook fan-out |
| `SubagentStop` | `cast-subagent-worktree-check.sh` | Scans for stale git worktrees left by the subagent and prunes them; isolated from main hook so git mutations get their own 10s budget |

### 5.2 `UserPromptSubmit` — `route.sh`

> **Historical (CAST v2):** The `UserPromptSubmit` hook (`route.sh`) was removed in CAST v3. Dispatch is now model-driven — the model reads the CLAUDE.md dispatch table and decides which agent to call. This section is preserved for protocol documentation.

**Stdin JSON schema:**
```json
{
  "prompt": "string — the user's raw input",
  "session_id": "string — current session identifier"
}
```

**Processing:** Extracts and lowercases the prompt. Skips if `CLAUDE_SUBPROCESS=1`. Matches against `~/.claude/config/routing-table.json` using regex patterns. Patterns longer than 200 characters are skipped (ReDoS prevention).

**Stdout on match:**
```json
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "[CAST-DISPATCH] Route: <agent> ..."
  }
}
```

**Stdout on no match:** empty (no output)

**Exit codes:**
- `0` — allow prompt to proceed (with or without injected context)
- `1` — warn (shown to Claude as context, but Claude can proceed)
- `2` — hard-block (Claude cannot proceed; not used by route.sh)

**Observability:** Every match and non-match is logged to `~/.claude/routing-log.jsonl`. Log is rotated at 5MB, keeping up to 2 rotated copies.

**CLAUDE_SUBPROCESS guard:** `route.sh` exits 0 immediately when `CLAUDE_SUBPROCESS=1`. Subagent prompts MUST NOT trigger re-routing — they are focused work delegations, not new user requests.

### 5.3 `PreToolUse` — `pre-tool-guard.sh`

**Stdin JSON schema:**
```json
{
  "tool_name": "string — name of the tool Claude is about to call",
  "tool_input": {
    "command": "string — the bash command (for Bash tool only)"
  }
}
```

**Processing:** Acts on Bash tool calls only — checks `command` against blocked operation patterns (git commit, git push). Validates escape hatches at position 0.

**Stdout on block:**
```
**[CAST]** Raw `git commit` blocked. Dispatch the `commit` agent instead.
```
(plain text — displayed to Claude as the block reason)

**Stdout on allow:** empty

**Exit codes:**
- `0` — allow the tool call
- `2` — hard-block; Claude cannot execute the command

Note: `pre-tool-guard.sh` does not output `hookSpecificOutput` JSON — it outputs plain text when blocking, which Claude Code displays as the block reason.

### 5.4 `PostToolUse` — `post-tool-hook.sh`

**Stdin JSON schema:**
```json
{
  "tool_name": "string — name of the tool that just completed",
  "tool_input": {
    "file_path": "string — for Write/Edit tools"
  }
}
```

**Processing (three parts, in order):**

1. **Auto-format** (all sessions including subagents): if `tool_name` is Write or Edit and `file_path` matches `.(js|jsx|ts|tsx|css|json)`, search for a `.prettierrc` config walking up the directory tree and run `npx prettier --write` if found.

2. **CAST-REVIEW injection** (main session only): if `CLAUDE_SUBPROCESS != 1` and `tool_name` is Write or Edit, output the `[CAST-REVIEW]` directive.

3. **CAST-ORCHESTRATE detection** (main session only): if `tool_name` is Write, `file_path` contains `/plans/`, and the file contains a `json dispatch` block, output the `[CAST-ORCHESTRATE]` directive.

**Stdout format for directive injection:**
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "[CAST-REVIEW] ..."
  }
}
```

**Exit codes:** Always 0 (no hard-blocking in post-tool-hook.sh).

### 5.5 `PostToolUse` — `agent-status-reader.sh`

> **Note:** In CAST v3, `agent-status-reader.sh` is no longer registered as a hook. Status propagation is handled by the model reading agent Status blocks directly. This section is preserved for protocol reference.

This legacy (v2) hook ran only in subagent context under the older headless/managed dispatch model, where subagents carried `CLAUDE_SUBPROCESS=1`. It inverts the standard guard (per §2.5, native Agent-tool subagents instead run with `CLAUDE_SUBPROCESS` **unset**, so this inversion no longer matches how in-session subagents execute):

```bash
if [ "${CLAUDE_SUBPROCESS:-0}" != "1" ]; then exit 0; fi
```

**Purpose:** After a subagent writes a status file via `cast_write_status`, this hook reads the latest status file and propagates the signal to the parent session.

**Stdin:** same PostToolUse schema as `post-tool-hook.sh`

**BLOCKED stdout:**
```
**[CAST-HALT]** Agent `<agent>` is BLOCKED and cannot proceed.
Summary: <summary>
Concerns: <concerns>
Resolve the blocker before continuing. Do not retry the blocked operation.
```
Exit code: `2` (hard-block)

**DONE_WITH_CONCERNS stdout:**
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "[CAST-REVIEW] Agent `<agent>` completed with concerns.\nSummary: ...\nConcerns: ...\nDispatch `code-reviewer` (haiku) to review before proceeding."
  }
}
```
Exit code: `0`

**DONE / NEEDS_CONTEXT / missing file:** exit 0 silently.

### 5.6 `hookSpecificOutput` Format

The `hookSpecificOutput` object is the standard envelope for injecting context into Claude's session:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit | PreToolUse | PostToolUse",
    "additionalContext": "string — the directive or context text"
  }
}
```

The `additionalContext` string appears in Claude's context window as if it were part of the conversation. Claude MUST treat directives in `additionalContext` as mandatory instructions.

---

## Section 6 — Event-Sourcing Protocol

CAST uses append-only event files instead of shared mutable state. Agents never share a
mutable file — each agent writes its own immutable event to the events/ directory.

### Directory Layout

All under `~/.claude/cast/`:

| Directory | Contents | Mutable? |
|---|---|---|
| `events/` | `{timestamp}-{agent}-{task_id}.json` — one file per agent action | Never (append-only) |
| `state/` | `{task_id}.json` — derived from events by main session | Derived (can be re-derived) |
| `reviews/` | `{artifact_id}-{reviewer}-{timestamp}.json` — review decisions | Never |
| `artifacts/` | Plans, patches, test files produced by agents | Never |

### Event File Schema

File: `{timestamp}-{agent}-{task_id}.json`

| Field | Type | Description |
|---|---|---|
| event_id | string | `{timestamp}-{agent}-{task_id}` |
| timestamp | ISO8601 | UTC timestamp |
| agent | string | Which agent emitted this event |
| task_id | string | Task being acted on (e.g., "batch-2") |
| parent_task_id | string\|null | Parent task for sub-tasks |
| event_type | string | See event types below |
| status | string\|null | DONE\|BLOCKED\|DONE_WITH_CONCERNS\|IN_PROGRESS |
| summary | string\|null | Human-readable description |
| artifact_id | string\|null | ID of artifact produced |
| concerns | string\|null | Details for DONE_WITH_CONCERNS |

### Event Types

| event_type | When emitted |
|---|---|
| task_created | planner creates a new task |
| task_claimed | agent begins working on a task |
| task_completed | agent finishes (with status field) |
| task_blocked | agent cannot proceed |
| task_rejected | reviewer rejects an artifact |
| artifact_written | agent produces a code/doc artifact |
| review_submitted | reviewer submits a decision |

### Review File Schema

File: `{artifact_id}-{reviewer}-{timestamp}.json`

| Field | Type | Description |
|---|---|---|
| review_id | string | `{artifact_id}-{reviewer}-{timestamp}` |
| artifact_id | string | Which artifact is being reviewed |
| reviewer | string | Agent that reviewed |
| decision | string | `approved` or `rejected` |
| timestamp | ISO8601 | UTC |
| feedback | string\|null | Specific review notes |
| recommended_agents | array | Follow-up agents recommended |

### Approval Gating

Before commit, the commit agent calls `cast_check_approvals <task_id> <required_reviewer...>`.

- Exit 0: all required approvals present — proceed
- Exit 1: missing approvals — block commit, request review
- Exit 2: unanswered rejections — block commit, rejection must be addressed first

Required approvals for a code commit: `code-reviewer` (mandatory) + `test-runner` (if tests exist).

### Why Not Shared State

Shared mutable JSON files create race conditions when agents run in parallel. The event-sourcing approach:
- Each agent writes only to its own timestamped file (no conflicts)
- State is always re-derivable from events (no corruption risk)
- Full causal history preserved for the dashboard
- Reviews are attached to specific artifact IDs (not to vague global task state)

---

## Section 7 — Fan-out Dispatch

Fan-out dispatch enables multiple specialist agents to work on a problem simultaneously, then synthesizes their independent findings before passing context to the next stage.

### 7.1 Manifest-Level Fan-out

Triggered by `"type": "fan-out"` in a manifest batch. The /orchestrate skill:

1. Dispatches all agents in the batch simultaneously (single response, multiple Agent tool calls)
2. Collects all agent responses
3. Synthesizes outputs into a **Fan-out Summary** paragraph
4. Prepends the Fan-out Summary to the prompt of every agent in the immediately following batch

**Fan-out Summary format:**
```
Fan-out Summary (Batch <id>):
- <agent-a>: <main finding in one sentence>
- <agent-b>: <main finding in one sentence>
[Conflicts: <describe any contradictory findings between agents>]
```

### 7.2 Agent-Level Fan-out

An agent may itself dispatch multiple sub-specialists simultaneously. This is agent-level fan-out. The agent:

1. Identifies independent sub-tasks that can run in parallel
2. Dispatches all sub-specialist agents in a single response
3. Synthesizes outputs before reporting its own Status block

### 7.3 Constraints

- Maximum 4 agents per fan-out batch (the /orchestrate skill enforces this; planner MUST respect it when building manifests)
- Agents in a fan-out batch MUST NOT depend on each other's outputs
- A fan-out / parallel batch MUST NOT co-schedule `test-runner` (or any process-killing / test-executing agent) with a review agent (`code-reviewer`, `security`, `frontend-qa`) — `test-runner`'s suite-timeout/kill path can reap co-scheduled sibling processes (observed 2026-06-14); `test-runner` runs in its own sequential batch
- The synthesizing agent (main session or dispatching agent) MUST produce a Fan-out Summary before passing context forward
- Fan-out does not imply fan-in review is skipped — quality gates still apply to the synthesized output

---

## Implementing CAST Compatibility

### Checklist: CAST-compatible agent

A CAST-compatible agent MUST:

- [ ] Include a YAML frontmatter block at the top of the `.md` file with fields: `name`, `description`, `tools`, `model`
- [ ] Output a Status block (`Status: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT`) as the last content in every response
- [ ] Include `Summary:` in every Status block
- [ ] Include `Blocker:` when status is BLOCKED
- [ ] Include `Concerns:` when status is DONE_WITH_CONCERNS
- [ ] If code-modifying: source `status-writer.sh` and call `cast_write_status` with matching values
- [ ] Never dispatch another instance of itself (prevents infinite loops)
- [ ] Not re-dispatch `code-reviewer` if it self-dispatches internally (self-dispatching agents: `backend-writer`, `frontend-writer`, `debugger`)
- [ ] Use `CAST_COMMIT_AGENT=1 git commit` (not raw `git commit`) if it needs to commit directly

A CAST-compatible agent SHOULD:

- [ ] Declare `memory: local` and consult `MEMORY.md` in `~/.claude/agent-memory-local/<name>/` before starting
- [ ] Use `disallowedTools` to prevent unintended side effects (e.g., `code-reviewer` disallows Write and Edit)
- [ ] Include a `maxTurns` limit appropriate for the task scope
- [ ] Keep prompts specific — include feature names, file paths, and plan paths when available

### Checklist: CAST-compatible hook script

A CAST-compatible hook script MUST:

- [ ] Read the full stdin payload before processing
- [ ] Guard against subagent re-entry using `CLAUDE_SUBPROCESS`: exit 0 for hooks that should only run in the main session; invert the guard for hooks that only run inside subagents
- [ ] Use `realpath` + `$HOME/` prefix check before reading or writing any file path derived from input
- [ ] Use exit code 0 (allow), 1 (warn), or 2 (hard-block) — never exit with other codes for protocol responses
- [ ] Output `hookSpecificOutput` JSON for directive injection; output plain text for block messages
- [ ] Limit regex pattern length to 200 characters maximum (ReDoS prevention)
- [ ] Log dispatch events to `cast.db` via `cast-cost-tracker.sh` (for PostToolUse:Agent hooks)
- [ ] Use `python3` stdlib only — no pip packages

A CAST-compatible hook script SHOULD:

- [ ] Use `set -euo pipefail` for fail-fast behavior
- [ ] Scope sensitive values as env-prefix subprocess invocations rather than `export` (prevents leaking to unrelated subprocesses)
- [ ] Emit nothing to stdout when taking no action (silence = allow)

---

## Appendix A — Directory Layout

```
~/.claude/
├── CLAUDE.md                        # Dispatch table + post-chain protocol (loaded every session)
├── agents/                          # Agent definition files (.md with YAML frontmatter)
├── scripts/
│   ├── pre-tool-guard.sh            # PreToolUse:Bash hook: git commit/push guard
│   ├── post-tool-hook.sh            # PostToolUse:Write|Edit hook (review injection)
│   ├── cast-cost-tracker.sh         # PostToolUse:Agent hook (logs to cast.db)
│   ├── cast-session-end.sh          # Stop hook: archival, pruning, memory sync
│   ├── status-writer.sh             # Sourced helper: cast_write_status
│   ├── cast-events.sh               # Sourced helper: cast_emit_event
│   ├── cast-validate.sh             # System integrity checker
│   ├── cast-stats.sh                # Usage analytics from cast.db
│   ├── cast-cron-setup.sh           # Cron installer for scheduled tasks
│   └── cast-db-init.sh              # Initialize cast.db schema
├── rules/                           # Stack context, project catalog, conventions
├── plans/                           # Plan files with Agent Dispatch Manifests
├── agent-status/                    # Per-agent JSON status files
├── agent-memory-local/              # Per-agent persistent memory
│   └── <agent-name>/MEMORY.md
├── cast.db                          # SQLite: sessions, agent_runs, budgets, agent_memories
├── cast/
│   ├── events/                      # Immutable event files
│   └── orchestrate-checkpoint.log   # /orchestrate skill batch progress
├── briefings/                       # Morning briefing outputs
├── meetings/                        # Meeting notes outputs
└── reports/                         # Report outputs
```

## Appendix B — Routing Table Schema

> **Historical (CAST v2):** The routing table was removed in CAST v3. This section is preserved for protocol documentation.

Each entry in `routing-table.json` under the `routes` array:

```json
{
  "patterns": ["regex1", "regex2"],
  "agent": "agent-name",
  "model": "haiku | sonnet | opus",
  "command": "/slash-command",
  "confidence": "hard | soft",
  "post_chain": ["agent-a", "agent-b"] | null | ["auto-dispatch-from-manifest"]
}
```

`post_chain: ["auto-dispatch-from-manifest"]` is a special sentinel used for the `planner` route. It tells route.sh not to append a `[CAST-CHAIN]` directive — the manifest itself drives the post-chain via `[CAST-ORCHESTRATE]`.

## Appendix C — Version History

| Version | Changes |
|---|---|
| 2.1.0 | CAST v3.3 (Phase 11): WAL mode, structured error logging, SQL injection fix, PII advisory mode, orchestrator checkpoints + policy gate, TRUNCATED/BLOCKED classification split, approval gate removed. |
| 2.0.0 | CAST v3: Removed routing table and route.sh. Model-driven dispatch via CLAUDE.md. Consolidated 42→15 agents (registry now 23). 4 hooks (pre-tool-guard, post-tool-hook, cast-cost-tracker, cast-session-end). Added cast.db observability. Replaced castd daemon with cron. |
| 1.5.0 | Added orchestrator, fan-out dispatch, task board, agent-status-reader, CAST-ORCHESTRATE and CAST-HALT directives |
| 1.0.0 | Initial protocol: Status Blocks, escape hatches, route.sh, pre-tool-guard.sh, post-tool-hook.sh |
