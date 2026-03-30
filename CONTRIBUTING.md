# Contributing to CAST

## Local Setup

```bash
git clone https://github.com/ek33450505/claude-agent-team.git
cd claude-agent-team
bash install.sh
cast doctor
```

`cast doctor` should show no ERRORs before you begin work. Warnings about optional tools can be ignored for most contributions.

---

## Running Tests

**Quick smoke test:**

```bash
tests/bats/bin/bats tests/cast-cli.bats
```

**Full suite (same list used by CI):**

```bash
tests/bats/bin/bats \
  tests/cast-events.bats \
  tests/post-tool-hook.bats \
  tests/cast-agent-stats.bats \
  tests/cast-mismatch.bats \
  tests/upgrade_check.bats \
  tests/cast_run.bats \
  tests/cast-memory.bats \
  tests/queue_status.bats \
  tests/cast-validate.bats \
  tests/cast-cli.bats \
  tests/compat.bats \
  tests/cast-security-guard.bats \
  tests/install.bats \
  tests/cast-weekly-report.bats \
  tests/cast-post-compact-hook.bats \
  tests/cast-task-created-hook.bats \
  tests/cast-instructions-loaded-hook.bats
```

**Files excluded from CI (skip locally too unless services are running):**

| File | Reason |
|---|---|
| `tests/agent-status-reader.bats` | Requires a live castd daemon |
| `tests/cast_exec.bats` | Requires a running castd / external process |
| `tests/compat_suite.bats` | Contains `airgap_state` test requiring live airgap state |

---

## Adding an Agent

1. Create `~/.claude/agents/<agent-name>.md` with required frontmatter:

   ```yaml
   ---
   name: agent-name
   description: One-line description used for dispatch routing
   tools: [Read, Write, Edit, Bash]
   model: claude-haiku-4-5   # or claude-sonnet-4-5
   ---
   ```

2. In Step 0 of the agent body, emit a `task_claimed` event:

   ```bash
   source ~/.claude/scripts/cast-events.sh
   cast_emit_event 'task_claimed' 'agent-name' 'batch-1' '' 'Starting task' 'CLAIMED'
   ```

3. End every response with a structured `Status:` block:

   ```
   Status: DONE
   Summary: what was accomplished
   ```

   Valid values: `DONE`, `DONE_WITH_CONCERNS`, `BLOCKED`, `NEEDS_CONTEXT`.

4. Add the agent file to the copy list in `install.sh` so it is installed for new users.

5. Add a BATS test file at `tests/<agent-name>.bats` covering at least: happy path, missing input, and expected output format.

---

## Submitting a PR

**Branch naming:**
- `feature/<short-description>` for new functionality
- `fix/<short-description>` for bug fixes
- `docs/<short-description>` for documentation-only changes

**Before opening the PR:**
- Run `cast validate` — it must pass with no new failures
- Run the smoke test (`tests/bats/bin/bats tests/cast-cli.bats`)
- Update `CHANGELOG.md` for any user-visible change

**What reviewers look for:**
- No hardcoded paths — use `$HOME` or `~/` throughout
- Agent frontmatter is complete and model tier is correct (sonnet for heavy tasks, haiku for lightweight)
- New hooks are wired in `~/.claude/settings.json` template and `install.sh`
- Test coverage exists for new behavior
- `Status:` block is present and correctly formed in every agent response path
