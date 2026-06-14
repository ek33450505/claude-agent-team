# v8-A1 Rules → Skills Migration

> Created 2026-06-14 as part of CAST v8-A1. This file is referenced by DUAL-KEEP comments in `rules-core/typescript.md`, `rules-core/python.md`, and `rules-core/scripts.md`.

## What Migrated

| Source rule(s) | Destination skill | Notes |
|---|---|---|
| `rules-core/typescript.md` | `skills/typescript-conventions/SKILL.md` | Verbatim body; `globs:` frontmatter stripped (skill description is the new semantic trigger) |
| `rules-core/python.md` + `rules-core/scripts.md` | `skills/python-conventions/SKILL.md` | Merged; scripts.md content lives under `## Script File Conventions` section header |
| `~/.claude/CLAUDE.md` `## Agent Registry` table | `skills/agent-registry/SKILL.md` | Registry expanded with one-line role description per agent |

## DUAL-KEEP Doctrine

During the proven-in phase, **both the rule file and the skill coexist**. The rule file (at `~/.claude/rules/`) is the safety net — it continues to inject its content into sessions via the always-on rules loader (or globs-gated loader, depending on Claude Code's rule resolution). The skill is declared in agent frontmatter and auto-loads unconditionally when those agents run.

This means no regression is possible during the proven-in phase: if the skill fails to load for any reason, the rule file is the fallback. The DUAL-KEEP comments in the source files mark the files as migration candidates and reference this doc for the retirement steps.

## Agents Updated (8 total)

| Agent | Skills after v8-A1 |
|---|---|
| `code-writer` | cast-conventions, stack-reference, typescript-conventions, python-conventions |
| `code-reviewer` | cast-conventions, typescript-conventions, python-conventions |
| `test-writer` | cast-conventions, typescript-conventions, python-conventions |
| `frontend-qa` | cast-conventions, typescript-conventions |
| `debugger` | cast-conventions, typescript-conventions, python-conventions |
| `bash-specialist` | cast-conventions, python-conventions |
| `devops` | cast-conventions, python-conventions |
| `planner` | cast-conventions, stack-reference, agent-registry |

## What Stayed Always-On

These rule files are NOT migrated and remain at `~/.claude/rules/` as always-on context:

- `working-conventions.md` — core behavioral: planning workflow, commit discipline, context management
- `shell.md` — CAST hook authoring conventions, R2 GUI-isolation HARD RULE, BATS teardown safety
- `tests.md` — temp-HOME isolation HARD RULE (destructive test policy; safety-critical)
- `claudes_journal.md` — journal behavioral directive (must fire at session end, not on demand)
- `managed-agents.md` — short behavioral preference (prefer managed agents over worktrees)
- `work-projects.md` — Bitbucket remote, Model B deploy, no push agent on work repos
- `stack-context.md` — already a thin pointer to stack-reference skill
- `project-catalog.md` — already a thin pointer to project-catalog skill
- `agents.md` — agent definition conventions (part of haiku-tier subset)

**Rule:** Files containing HARD RULEs or behavioral directives that must fire even when the agent doesn't know it will need them stay always-on. Language-specific coding conventions are safe to demand-load because the audience (agents that write/review/debug code) is well-defined and listed in frontmatter.

## Proven-In Gate

The DUAL-KEEP phase ends — and rule retirement begins — when:

1. At least **5 real code-writer dispatches** on TypeScript projects have completed without code-reviewer flagging any convention violations
2. At least **3 Python/script edits** have been made cleanly under the skill path
3. No quality regressions attributable to missing language conventions have been reported

## Retirement Steps

When the proven-in gate is cleared:

1. Delete the source files from `rules-core/`:
   ```bash
   rm rules-core/typescript.md rules-core/python.md rules-core/scripts.md
   ```

2. Add cleanup to `install.sh`'s retired-files block (similar to lines 236–239):
   ```bash
   rm -f "$CLAUDE_DIR/rules/typescript.md"
   rm -f "$CLAUDE_DIR/rules/python.md"
   rm -f "$CLAUDE_DIR/rules/scripts.md"
   ```

3. Run `bash install.sh` to propagate the removal to `~/.claude/rules/`.

4. Delete this doc's DUAL-KEEP comments from any remaining references (or update them to note retirement date).

## Driver: Plugin Portability

The primary driver for this migration is **plugin portability**: CAST plugins (planned for v8 Phase A1-P0) can carry skills but cannot carry rules. Language conventions and the agent registry table need to travel with the plugin so that installations that use only the plugin get full conventions coverage.

Token savings are a secondary win (~100–420 tokens, ~2–10% of always-on budget). The 50% reduction target requires a separate **Phase A1.5** (behavioral-rule slimming: `working-conventions.md`, `shell.md`, CLAUDE.md auto-memory conventions). That slimming is explicitly out of scope for v8-A1 — this plan covers language-rule portability only.
