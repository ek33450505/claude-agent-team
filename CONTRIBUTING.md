# Contributing to CAST

Thank you for your interest in contributing to CAST — Claude Agent Specialist Team.

## Prerequisites

- [Claude Code CLI](https://claude.ai/code) installed and configured
- [bats-core](https://github.com/bats-core/bats-core) — included as a submodule at `tests/bats/`
- Bash 5.0+
- `sqlite3` (for `cast.db` inspection)
- `jq` 1.6+

## Setup

```bash
git clone https://github.com/ek33450505/claude-agent-team.git
cd claude-agent-team
git config core.hooksPath .githooks
chmod +x .githooks/*
make hooks
bash install.sh
```

`install.sh` wires hook scripts into `~/.claude/scripts/` and `~/.claude/settings.json`.
If something looks wrong after install, run `cast doctor` to diagnose the setup.

> **Note:** Agent Step 0 code sources `~/.claude/scripts/cast-events.sh`, which ships via
> `install.sh`. Run `bash install.sh` at least once before writing or testing new agents.

---

## Running Tests

```bash
# Full suite
make test

# Single file
tests/bats/bin/bats tests/route.bats

# Ubuntu CI parity check (catches bash 4/5 divergence — run before opening a PR)
make test-ubuntu
```

**Counting tests:** use `git ls-files tests/*.bats | xargs grep -h "@test" | wc -l` — never
`find tests/ -name "*.bats"` (the vendored bats-core submodule inflates the count).

---

## Adding an Agent

1. Copy an existing agent from `agents/core/` as a starting point.
2. Edit the required frontmatter:

```yaml
---
name: <agent-name>
description: <one-line description used by Claude Code to select this agent>
tools: Read, Write, Edit, Bash
model: claude-haiku-4-5   # or claude-sonnet-4-5
effort: low               # low | medium | high
---
```

3. Add the agent to the registry table in `CLAUDE.md` (and the `CHEATSHEET.md` agents table).
4. Add a BATS test in `tests/` covering the agent's core behavior.

See `docs/agents/agent-quality-rubric.md` for how agents are evaluated. Aim for score 4–5 on all dimensions.

**Every agent must:**
- Emit a `task_claimed` event as its first action (Step 0).
- End every response with a structured `Status:` block (`DONE` | `DONE_WITH_CONCERNS` | `BLOCKED` | `NEEDS_CONTEXT`).

---

## Adding a Hook Script

1. Create the script in `scripts/` following the naming convention `cast-<purpose>-hook.sh`.
2. Wire it in `~/.claude/settings.json` under the appropriate hook event key.
3. Add a BATS test in `tests/`.
4. Ensure `bats-ci.yml` copies the new script in its CI setup step — both `*.sh` and `*.py` files must be copied, or CI hooks silently no-op on Ubuntu.

---

## Scope — Core vs Personal

CAST distinguishes between **core** (ships to all installs) and **personal** (maintainer-only overlay):

| Path | Scope | Review Bar |
|---|---|---|
| `agents/core/` | Core — all clones | High — generic, trustworthy |
| `agents/personal/` | Personal — `--personal` flag | Standard |
| `rules-core/` | Core | High |
| `rules-personal/` | Personal | Standard |

PRs targeting `agents/core/` or `rules-core/` should focus on generic, widely-useful features.

---

## Keeping Docs in Sync

README badge counts (agents, tests, etc.) are **auto-updated on merge to `main`** by the
`readme-badge-sync.yml` workflow — do NOT manually edit badge numbers.

If you add a new agent, command, or skill, run `make docs` locally to verify counts look
correct, but do not commit the README badge update — CI handles it post-merge.

---

## PR Checklist

- [ ] `bats tests/` passes locally (run `make test-ubuntu` for cross-platform check)
- [ ] New shell scripts have BATS test coverage in `tests/`
- [ ] If adding a new agent: frontmatter complete (`name`, `description`, `tools`, `model`, `effort`), added to `CLAUDE.md` registry and `CHEATSHEET.md`
- [ ] If adding a new hook script: wired in `settings.json`, script exists in `scripts/`, CI setup step copies it
- [ ] README badge NOT manually edited — auto-syncs on merge to `main`
- [ ] No `find tests/ -name "*.bats"` — use `git ls-files tests/*.bats` for test counts
- [ ] No hardcoded absolute paths — use `$HOME` or `~/`
- [ ] `CHANGELOG.md` updated for user-visible changes

---

## Good First Issues

New to the codebase? Start here:
[https://github.com/ek33450505/claude-agent-team/issues?q=label%3A%22good+first+issue%22](https://github.com/ek33450505/claude-agent-team/issues?q=label%3A%22good+first+issue%22)

Good first issues in this repo are:
- Self-contained (one file, or one script + one test)
- Under 2–4 hours
- Come with specific acceptance criteria and file pointers

If you're unsure where to start, open an issue or leave a comment on a good-first-issue ticket asking for guidance.
