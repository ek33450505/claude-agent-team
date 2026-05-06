# CAST Compatibility Matrix

This document describes the minimum Claude Code versions required for CAST features and
known breakages on older releases.

CAST itself has no hard version check in `install.sh` — it installs on any version.
However, several hook events and API features were introduced gradually and will silently
no-op or error on older builds.

---

## Feature Compatibility Table

| Feature | Min Claude Code Version | Notes |
|---|---|---|
| Core agent dispatch (Agent tool) | Any | Available since Claude Code GA |
| `SessionStart` hook event | ~v1.0 | Introduced at GA; fires once per new session |
| `PreToolUse` hook event | ~v1.0 | Fires before every tool call; exit 2 blocks the call |
| `PostToolUse` hook event | ~v1.0 | Fires after every tool call completes |
| `SubagentStop` hook event | ~v1.5 | Introduced with subagent (Agent tool) support |
| `StopFailure` hook event | ~v2.0 | Fires when an agent API call fails mid-task |
| `PreCompact` hook event | ~v2.0 | Fires before `/compact` context summary |
| `CwdChanged` hook event | ~v2.0 | Fires when working directory changes |
| Hook `matcher` field (pre-filter) | ~v2.0 | Replaces deprecated `if` field in hook entries |
| MCP tool hooks (`type: mcp_tool`) | v2.1.118+ | REC-03; blocked on v2.1.116 and earlier |
| Trail of Bits security skills | v2.1.118+ | `/plugin marketplace add trailofbits/skills` |
| `CLAUDE_SUBPROCESS` env var | ~v1.5 | Set to `1` inside subagent context; required for hook loop guard |
| `CLAUDE_ENV_FILE` env var | ~v2.0 | Optional; hooks write env vars for session continuity |
| `managed-agents-2026-04-01` API beta | API only | Managed Agents run on Anthropic infrastructure; not a Claude Code version gate |
| `initialPrompt` agent frontmatter | ~v2.0 | Auto-loads context on first agent turn |
| Extended thinking budgets | ~v2.0 | Per-agent `thinking` token allocations in frontmatter |
| `defaultMode: auto` frontmatter | ~v2.1 | Session-start bug present; use `--permission-mode auto` flag instead |

---

## Known Breakages on Older Versions

### SubagentStop not firing (< v1.5)

If you are on Claude Code < ~v1.5, the `SubagentStop` hook event does not exist.
CAST's `cast-subagent-stop-hook.sh` is registered but will never be called. Agent
dispatches still work; telemetry rows in `cast.db` will not be written.

**Fix:** `claude update` to the latest release.

### PreCompact hook not firing (< v2.0)

The `PreCompact` guard (which blocks `/compact` on dirty worktrees) requires the
`PreCompact` event introduced circa v2.0. On older builds the hook is silently skipped.

**Symptom:** `/compact` runs without the dirty-worktree check.

### CwdChanged not exporting CAST_REPO_CLASS (< v2.0)

The `CwdChanged` event is used by CAST to export `CAST_REPO_CLASS` (values: `personal`,
`work`) based on `.claude/cast.json`. On older builds this event does not fire.

**Symptom:** Repo-aware hooks behave as if no `cast.json` is present.

### MCP tool hooks silently no-op (< v2.1.118)

Hook entries with `"type": "mcp_tool"` are ignored on Claude Code < v2.1.118.
CAST does not ship any `mcp_tool` hooks by default, but custom hooks using this type
will not fire. Confirmed blocked at v2.1.116.

**Fix:** `claude update` to v2.1.118+.

---

## Checking your Claude Code version

```bash
claude --version
```

To update:

```bash
claude update
```

---

## BATS and bats-core version

CAST's test suite requires `bats-core` (not the legacy `bats` package):

```bash
brew install bats-core   # macOS
apt-get install bats     # Ubuntu/Debian
```

Tests are confirmed passing on bats-core 1.10+ and 1.11+.

---

## See also

- [Hook Authoring Guide](./hooks/authoring-guide.md)
- [Getting Started Tutorial](./tutorial/getting-started.md)
