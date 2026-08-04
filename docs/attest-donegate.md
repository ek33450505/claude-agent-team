# Attest DONE-Gate

## What

Attest is a local, zero-LLM SubagentStop "DONE-gate" installed as a Claude Code plugin.
It snapshots the git tree at SubagentStart and, at SubagentStop, blocks a subagent's
`Status: DONE` when its claimed `files_changed` are absent from BOTH the git delta AND
disk — catching completions that never actually landed.

**Fail-open on every doubt.** Attest blocks only when it is certain a claim is false.
It passes through silently when any of the following hold:

- The repo is not a git repository
- The working tree is dirty at start-time (snapshot unreliable)
- The snapshot is missing (SubagentStart did not fire)
- The claimed file is gitignored but exists on disk
- The agent emitted no `files_changed` claim
- No `agent_id` is present in the stop payload
- The signal is ambiguous for any other reason

Verdicts are mirrored to `cast.db` in the `attestations` table regardless of the
block/pass decision, providing an audit trail even when fail-open fires.

**Repo:** <https://github.com/ek33450505/attest>

---

## Status in CAST: OFF by default

The plugin is **installed but disabled** (`defaultEnabled: false` in plugin manifest).
The on-switch (`ATTEST_ENFORCE=1`) is deliberately **not set** in
`managed-settings.d/00-env.json`.

In its **current state — plugin disabled** — attest is fully inert: no SubagentStart
snapshots, no SubagentStop verdicts, no blocks. Nothing fires until the plugin is enabled.

Once the plugin is **enabled but `ATTEST_ENFORCE` is unset** (detect mode):

- SubagentStart snapshots are taken (the hook fires)
- SubagentStop computes verdicts and writes them to `cast.db`
- **No subagent is ever blocked** — detect/no-block mode

The scope is **pre-wired**: `ATTEST_ENFORCE_AGENTS=backend-writer,frontend-writer,bash-specialist` is set in
`managed-settings.d/00-env.json`. When enforcement is enabled, only those three
artifact-producing agents are ever blockable; every other agent (code-reviewer, security,
commit, researcher, devops, etc.) fails open by construction — the scope key is evaluated
before any block decision is made. **Scope evaluation requires the attest plugin to be
v0.3.0+** (the version that ships `ATTEST_ENFORCE_AGENTS`); with an older plugin the scope
key is silently ignored and enforcement is **unscoped** — see Step 1 below before enabling.

---

## How to turn it ON (opt-in)

> **Read all three steps before enabling. Enabling out of order breaks the scope guard.**

### Step 1 — Verify the installed plugin version

The allowlist (`ATTEST_ENFORCE_AGENTS`) requires attest **v0.3.0 or later**.

```bash
claude plugin list   # shows installed plugins, version, and enabled/disabled status
```

A stale plugin (≤ 0.2.0) ignores `ATTEST_ENFORCE_AGENTS` entirely and would enforce on
**every** agent if `ATTEST_ENFORCE=1` is set. **Do not proceed to Step 2 until you have
confirmed v0.3.0+.**

### Step 2 — Enable the plugin

```bash
claude plugin enable attest@attest
```

The bare `claude plugin enable attest` fails with "not found in any editable settings scope" —
the `plugin@marketplace` qualifier (as shown in `claude plugin list`) is required.

### Step 3 — Set the enforcement on-switch in your session

```bash
export ATTEST_ENFORCE=1
```

Or add it to your shell profile / `managed-settings.d/` for persistence. The switch
is intentionally NOT committed to the repo — it is a per-operator decision.

---

## Tuning knobs

| Variable | Default | Effect |
|---|---|---|
| `ATTEST_ENFORCE` | unset | Master on-switch. Must be `1` to block. |
| `ATTEST_ENFORCE_AGENTS` | `backend-writer,frontend-writer,bash-specialist` | Comma-separated allowlist of agent types that can be blocked. Already set in `managed-settings.d/00-env.json`. |
| `ATTEST_MAX_RETRIES` | `1` | Per-agent block cap before attest stops blocking that agent in the session. Set to `0` for a kill-switch (attest never blocks). |
| `ATTEST_SESSION_BLOCK_CEILING` | `10` | Session-wide backstop: after this many total blocks, attest fails open for the rest of the session. |

---

## Composition with existing CAST hooks

CAST's existing SubagentStop hooks emit a `hookSpecificOutput` JSON key (context for the
session, not a block signal). Attest emits `{"decision": "block"}` via stdout with exit 0
when it fires, which is the Claude Code hook block protocol.

There is no decision collision: `hookSpecificOutput` and `{"decision":"block"}` are
orthogonal fields in the hook response envelope. Attest is registered with
`async: false` (required for blocking hooks); the existing CAST SubagentStop hooks are
`async: true`. The two co-exist without interference.

**Smoke-test before trusting it live.** Run a synthetic subagent that claims a file it
never wrote, confirm the block fires, then confirm a real backend-writer or frontend-writer dispatch that
actually writes files passes through unblocked.

---

## cast.db

The `attestations` table (declared in `cast-db-init.sh`) records every verdict:

| Column | Description |
|---|---|
| `agent_key` | Agent identifier from the SubagentStop payload |
| `false_done` | `1` if a false-done was detected, `0` if the claim checked out |
| `payload` | Full JSON payload from the stop event |

Query example:

```sql
SELECT agent_key, false_done, json_extract(payload, '$.files_changed') AS claimed
FROM attestations
WHERE false_done = 1
ORDER BY rowid DESC
LIMIT 20;
```
