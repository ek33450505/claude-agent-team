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
| Hook `matcher` field (pre-filter) | ~v2.0 | `matcher` filters the hook group; `if` is still a live per-handler field (permission-rule syntax, evaluated on PreToolUse/PostToolUse/PostToolUseFailure/PermissionRequest/PermissionDenied). Matchers exact-match hyphenated names since 2.1.195; a single-segment `dir/**` `if` matches only `<cwd>/dir` since 2.1.214 (hooks docs; CC changelog 2.1.195, 2.1.214) |
| MCP tool hooks (`type: mcp_tool`) | v2.1.118+ | REC-03; blocked on v2.1.116 and earlier |
| Trail of Bits security skills | v2.1.118+ | `/plugin marketplace add trailofbits/skills` |
| `CLAUDE_SUBPROCESS` env var | ~v1.5 | Set to `1` inside subagent context; required for hook loop guard |
| `CLAUDE_ENV_FILE` env var | ~v2.0 | Optional; hooks write env vars for session continuity |
| `managed-agents-2026-04-01` API beta | API only | Managed Agents run on Anthropic infrastructure; not a Claude Code version gate |
| `initialPrompt` agent frontmatter | ~v2.0 | Auto-loads context on first agent turn |
| Extended thinking budgets | ~v2.0 | Per-agent `thinking` token allocations in frontmatter |
| `defaultMode: auto` frontmatter | ~v2.1 | CC changelog 2.1.292 fixed subagents with `permissionMode: auto` entering auto mode when it is unavailable; not re-probed in CAST |
| `onFailure: "block"` hook field | v2.1.295 | Older builds ignore the key, so CAST's three fail-closed guards in `managed-settings.d/25-hooks-security.json` fail OPEN there (CC changelog 2.1.295). `mcp_tool` hooks honour it from 2.1.328. |
| `Tool(param:value)` permission rules (e.g. `Agent(model:…)`) | v2.1.178 | Used in `managed-settings.d/11-deny.json` (CC changelog 2.1.178) |
| `sandbox.credentials` | v2.1.187 | Used in `managed-settings.d/61-sandbox.json` (CC changelog 2.1.187) |
| `duration_ms` in PostToolUse/PostToolUseFailure input | v2.1.119 | Present in the input; no CAST PostToolUse hook reads it yet (CC changelog 2.1.119) |
| `scratchpad_dir` hook input field | v2.1.257 | Present in SubagentStop input; CAST does not read it (hooks docs) |
| `background_tasks` / `session_crons` in Stop/SubagentStop input | v2.1.145 | (CC changelog 2.1.145) |
| `CLAUDE_CODE_MAX_SUBAGENTS_PER_SESSION` | removed v2.1.224 | No-op; removed from `00-env.json` (env-vars docs) |
| `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` | v2.1.217 | Native default became 3 in 2.1.219; CAST pins `1` on purpose so reviewers run from the dispatching session (CC changelog 2.1.217, 2.1.219) |
| `CLAUDE_CODE_SUBAGENT_MODEL` / `_FORCE` | v2.1.251 / v2.1.257 | The plain var is a default, not an override, since 2.1.251; `_FORCE` overrides everything (CC changelog 2.1.251, 2.1.257) |
| Task tools (`TaskCreate`/`TaskUpdate`/`TaskList`/`TodoWrite`) | v2.1.233 | Not offered on current models unless `CLAUDE_CODE_ENABLE_TODO_TOOLS=1`, which CAST sets in `00-env.json` for `/orchestrate` (CC changelog 2.1.233, 2.1.268) |
| Agent teams (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`) | v2.1.178 | `TeamCreate`/`TeamDelete` removed; one implicit team per session (CC changelog 2.1.178) |
| `permissions.defaultMode: auto` from settings | v2.1.257 | `auto`/`bypassPermissions` are ignored in project/local settings; set them in user or managed settings (settings docs; CC changelog 2.1.257) |
| `SessionEnd` hook timeout | v2.1.268 | Hooks without a per-hook `timeout` are cancelled after 1.5 s; CAST sets `timeout: 15` in `30-hooks-session.json` (CC changelog 2.1.268) |
| `UserPromptSubmit` before slash expansion | v2.1.299 | Hooks see the raw `/command` text; CAST's memory recall skips command-shaped prompts (CC changelog 2.1.299) |
| `OTEL_*` not inherited by hooks/Bash | v2.1.128 | OTel export is configured only through user-scope env (`12-otel.json`, written by `scripts/cast-otel.sh enable`) (CC changelog 2.1.128) |
| Subagents run in background by default | v2.1.198 | Extended to all non-teammate spawns in 2.1.232; the dispatching session verifies the diff on disk before reading a verdict (CC changelog 2.1.198, 2.1.232) |
| `PostModelSwitch` / `PreModelSwitch` hook events | v2.1.251 | CAST records `PostModelSwitch` via `cast-model-switch-hook.sh`; `PreModelSwitch` unused (CC changelog 2.1.251) |

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
# Ubuntu/Debian: apt-get install bats installs the legacy package (bats < 1.0).
# For bats-core (1.10+), use npm or install from source:
#   npm install -g bats
#   OR: git clone https://github.com/bats-core/bats-core && cd bats-core && sudo ./install.sh /usr/local
# Verify: bats --version (must be >= 1.10)
```

Tests are confirmed passing on bats-core 1.10+ and 1.11+.

---

## See also

- [Hook Authoring Guide](./hooks/authoring-guide.md)
- [Getting Started Tutorial](./tutorial/getting-started.md)
