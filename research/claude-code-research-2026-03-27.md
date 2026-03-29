# Claude Code Research Report — 2026-03-27

Research conducted against official docs, CHANGELOG.md (anthropics/claude-code), and community sources.
Versions covered: 2.1.74 through 2.1.85 (the current release range as of research date).

---

## New Capabilities (not yet broadly known)

### Agent Teams (experimental, v2.1.32+)
A fundamentally different architecture from subagents. Teammates run as fully independent Claude Code sessions that communicate directly with each other — they do not route all messages through the lead.

Enable: `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` in `settings.json` or shell env.

Architecture:
- **Team lead**: the originating session; creates tasks, spawns teammates, synthesizes
- **Teammates**: independent Claude instances with own context windows
- **Shared task list**: stored at `~/.claude/tasks/{team-name}/`, uses file locking for race-condition-safe claiming
- **Mailbox**: async messaging between agents; lead does not need to poll

Key differences vs subagents:
| | Subagents | Agent Teams |
|---|---|---|
| Context | Own window; results summarized back | Own window; fully independent |
| Communication | Report to main agent only | Message each other directly |
| Coordination | Main agent manages all work | Shared task list, self-coordination |
| Token cost | Lower | Higher (scales linearly with team size) |

Display modes: `in-process` (any terminal, Shift+Down to cycle) or `split-panes` (tmux or iTerm2 with `it2` CLI).

Known limitations: no `/resume` for in-process teammates, no nested teams, one team per session, lead is fixed at spawn.

Best starting team size: 3–5 teammates. 5–6 tasks per teammate is optimal.

### 1M Context Window for Opus 4.6 (v2.1.75)
Opus 4.6 default max output increased to 64K tokens (upper bound: 128K) in v2.1.77. As of v2.1.75, Opus 4.6 gets a 1M context window on Max, Team, and Enterprise plans. This fundamentally changes what fits in a single-session subagent.

### `--bare` Flag for Scripted Calls (v2.1.81)
`claude --bare -p "..."` skips hooks, LSP, and plugin sync. Requires `ANTHROPIC_API_KEY`. Designed for CI/scripted pipelines where hook overhead is unwanted.

### `--channels` Permission Relay (v2.1.81, research preview)
Allows MCP servers to push messages into sessions and relay tool permission approvals to mobile. Enables channel-based permission delegation from remote devices.

### Conditional Hook Execution (v2.1.85)
Hooks now support an `if` field using permission rule syntax (e.g., `Bash(git *)`). Hooks only fire when the condition matches. This eliminates the need for condition logic inside hook scripts.

### `initialPrompt` for Agent Frontmatter (v2.1.83)
Agents can declare `initialPrompt` in their frontmatter. The prompt is auto-submitted on the first turn without user input. Enables fully hands-off agent launching.

### `effort` Frontmatter for Skills and Agents (v2.1.80)
Skills and agents now support an `effort` frontmatter key to override the model's compute effort level. `/effort` slash command available interactively.

### MCP Elicitation (v2.1.76)
MCP servers can now request structured user input mid-task via a dialog or browser. Two new hook events support this: `Elicitation` and `ElicitationResult`. Hooks can intercept elicitations, pre-fill form values, or cancel them entirely.

### `SendMessage` Auto-Resume (v2.1.81)
`SendMessage({to: agentId})` now auto-resumes stopped agents. Previously stopped agents required manual restart before receiving messages.

### Background Agent Partial Results (v2.1.81)
Background agents now preserve partial results when killed. Output is readable even from interrupted runs.

### `managed-settings.d/` Drop-in Directory (v2.1.83)
Policy fragments can now be placed in `managed-settings.d/` as individual JSON files alongside `managed-settings.json`. Enables composable, per-policy governance without editing a monolithic settings file.

### `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` (v2.1.83)
New env var strips credentials from subprocess environments before execution. Security hardening for multi-agent pipelines where subprocesses shouldn't inherit secrets.

### Transcript Search (v2.1.83)
Press `/` in transcript mode (`Ctrl+O`) to search transcripts. `n`/`N` steps through matches. Previously no search capability existed in transcript view.

### Cron / Scheduled Tasks with Timestamps (v2.1.85)
Timestamp markers are now injected into transcripts for scheduled tasks (`/loop`, `CronCreate`). Makes it easier to audit when scheduled agent actions actually fired.

### `CLAUDE_PLUGIN_DATA` Persistent Plugin State (v2.1.78)
New env var pointing to per-plugin persistent state directory. State survives plugin updates, enabling plugins to maintain memory across versions.

### Deep Link Character Limit Expansion (v2.1.85)
`claude-cli://open?q=...` deep links now support up to 5,000 characters (was much less). Enables richer pre-loaded prompts from external apps.

### MCP Tool Description Cap (v2.1.84)
MCP tool descriptions are now capped at 2KB. This is a context-hygiene enforcement measure — oversized tool descriptions were silently consuming context budget.

### `rate_limits` in Statusline Scripts (v2.1.80)
Statusline scripts can now read `rate_limits` with 5-hour and 7-day usage windows, including `used_percentage` and `resets_at`. Enables dashboards that show burn rate in real time.

### Rules/Skills `paths:` as YAML List (v2.1.84)
`paths:` frontmatter in rules and skills files now accepts a YAML list of globs (not just a single string). Enables a single skills file to apply across multiple path patterns.

### PowerShell Tool for Windows (v2.1.84, opt-in preview)
Windows users can now opt into a PowerShell tool via settings. Brings Windows to parity with Bash on macOS/Linux for scripted actions.

---

## New MCP Tools / Integrations

### Anthropic MCP Registry
Official registry at `https://api.anthropic.com/mcp-registry/v0/servers`. Queryable via API. Servers are tagged by compatibility (`claude-code`, `claude-api`, `claude-desktop`). This is the authoritative source for first-party and commercial MCP servers.

### MCP OAuth — RFC 9728 (v2.1.85)
Claude Code now follows RFC 9728 Protected Resource Metadata discovery for MCP OAuth flows. Required for production MCP servers that use token-based auth against real resource servers.

### `steipete/claude-code-mcp`
Claude Code itself exposed as a one-shot MCP server. Enables "agent in your agent" patterns where a parent orchestrator calls Claude Code as a tool. Source: https://github.com/steipete/claude-code-mcp

### Community MCP Servers (notable, published recently)
- **GitHub MCP Server** (official): PR management, issue creation, code search
- **PostgreSQL MCP**: natural language to SQL queries
- **SQLite MCP**: embedded database management
- **Playwright MCP**: browser automation as MCP tools (seen in `fcakyon/claude-codex-settings`)
- **Tavily MCP**: web search as MCP tool (in `fcakyon/claude-codex-settings`)
- **MongoDB MCP**: in `fcakyon/claude-codex-settings`
- **Azure MCP**: cloud resource management

### Context Budget Warning
The community has established a hard limit: keep under 10 MCP servers active and under 80 total tools. Too many MCPs shrink effective context from 200K to ~70K tokens.

### `allowedMcpServers` / `deniedMcpServers` Policy Enforcement (v2.1.78)
Fixed: `--mcp-config` was previously bypassing these managed settings. Now properly enforced. Organization policies can now reliably allowlist/denylist MCP servers.

### `allowedChannelPlugins` Managed Setting (v2.1.84)
New managed setting for organization-level plugin allowlisting by channel. Relevant for enterprise deployments with channel-based permission relays.

---

## Deprecated Patterns

### `TaskOutput` Tool — Deprecated
`TaskOutput` tool is deprecated. Background task output should now be read via the `Read` tool on the output files written by the background agent. Any agent definitions referencing `TaskOutput` should be updated.

### Windows Legacy Managed Settings Path — Removed
`C:\ProgramData\ClaudeCode\` is no longer the managed settings location on Windows. Teams using Windows with managed policy deployment need to update their paths.

### `--plugin-dir` Multiple Path Pattern — Changed
`--plugin-dir` now only accepts a single path. Previously it accepted multiple paths in some forms. Use repeated `--plugin-dir` flags for multiple plugin directories.

### `/fork` — Renamed to `/branch` (alias maintained, v2.1.77)
`/fork` is renamed to `/branch`. The old command still works as an alias, but new tooling and docs use `/branch`.

### Inline Subagent Orchestration (community consensus)
Community pattern emerging: do not inline-orchestrate more than 3–4 subagents. Beyond that, the cognitive load of deciding agent assignment outweighs the gains. Use Agent Teams for truly parallel work.

### Using All MCPs at Once
Enabling every available MCP server in settings is now considered an anti-pattern. The context budget cost is well-documented and measurable. Profile and selectively enable.

---

## Anthropic Best Practice Alignment Opportunities for CAST

### 1. Adopt Conditional Hook `if` Field (v2.1.85)
CAST hooks can shed internal condition logic by moving filtering to the `if` frontmatter field. Example: a pre-tool hook that only fires on `Bash(git *)` calls can declare that condition declaratively instead of branching inside the script.

### 2. `TeammateIdle` + `TaskCreated` + `TaskCompleted` Hooks for Quality Gates
CAST's `code-reviewer` post-chain pattern maps directly to these three hook events for Agent Teams. Instead of (or in addition to) CAST's routing-table `post_chain`, quality enforcement can be delegated to hooks that block task completion until lint/tests pass. This is idempotent and fires regardless of whether the post-chain was dispatched.

### 3. Agent `initialPrompt` Frontmatter
CAST agents that currently rely on the CAST-DISPATCH directive to receive their initial context could instead declare `initialPrompt` in frontmatter for fully zero-touch launch. Reduces the inline session's orchestration surface area.

### 4. `effort` Frontmatter to Match CAST Model Tiers
CAST's haiku-vs-sonnet agent split is a rough approximation of compute budget. The `effort` frontmatter key allows more granular control per-skill rather than just per-model. `report-writer` (haiku) could use `effort: low`; `architect` (sonnet) could use `effort: high`.

### 5. `managed-settings.d/` for CAST Policy Composition
If CAST ever moves toward team or enterprise deployment, the drop-in directory pattern directly enables CAST's per-agent capability restrictions (e.g., `security` agent gets broader permissions than `commit`) as individual policy fragments rather than a single monolithic settings file.

### 6. Agent Teams for CAST War Room / Parallel Review
The `CAST-DISPATCH-GROUP` + parallel waves pattern in CAST's routing table is essentially a manual implementation of Agent Teams. For sufficiently complex tasks (competing hypotheses, parallel domain review), Agent Teams provide native infrastructure that CAST's orchestrator currently replicates in shell. The limitation (experimental, no `/resume` for in-process) means this is not a drop-in replacement yet — but CAST's architecture already mirrors the recommended pattern.

### 7. `SubagentStop` Hook for CAST Turn Limit / Resume Protocol
CAST's turn-limit-and-resume protocol is manual. The `SubagentStop` hook (can block stopping with `decision: "block"` + reason) provides a hook-level equivalent: a stop hook can check whether the agent is mid-task and inject a checkpoint log before allowing stop, rather than relying on the agent to self-manage the ceiling.

### 8. `StopFailure` Hook for Rate Limit Alerting
CAST's orchestrator has no current mechanism to surface API rate limits or billing failures from subagents. The `StopFailure` hook fires with an `error` field (`rate_limit`, `billing_error`, etc.) and can write to a log or alert. Implementing this in CAST would make rate-limit-related BLOCKED states visible immediately.

### 9. `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` for Security Agents
CAST's `security` and `pentest` agents run subprocesses. Enabling env scrubbing prevents API keys from leaking into those subprocess environments — especially relevant for pentest scenarios where subprocess output may be inspected externally.

### 10. Reduce Active MCPs Below 10
If CAST sessions are loading many MCPs simultaneously (Atlassian, GitHub, DB, etc.), context budget is being consumed. A CAST rule in `CLAUDE.md` or a `PreToolUse` hook that warns when >10 MCPs are active would be actionable.

---

## Raw Notes

### Version Timeline (recent)
- **2.1.85**: Conditional hooks `if` field; RFC 9728 MCP OAuth; `TaskCreated` hook; `CLAUDE_CODE_MCP_SERVER_NAME/URL` env vars
- **2.1.84**: PowerShell tool (Windows, preview); `TaskCreated` hook; `WorktreeCreate` for HTTP; `allowedChannelPlugins`; MCP tool description 2KB cap
- **2.1.83**: `managed-settings.d/`; `CwdChanged` + `FileChanged` hooks; `sandbox.failIfUnavailable`; transcript search; `initialPrompt` frontmatter; `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB`
- **2.1.81**: `--bare` flag; `--channels` preview; `SendMessage` auto-resume; background agent partial results
- **2.1.80**: `rate_limits` in statusline; `effort` frontmatter; `--channels` research preview
- **2.1.79**: `--console` flag (Anthropic Console auth); deep links in preferred terminal
- **2.1.78**: `StopFailure` hook; `CLAUDE_PLUGIN_DATA`; line-by-line response streaming; security fix: sandbox disable + protected dirs in bypassPermissions
- **2.1.77**: Opus 4.6 max output 64K (cap 128K); `allowRead` sandbox setting; `/copy N`; `/fork` → `/branch`
- **2.1.76**: MCP elicitation; `Elicitation` + `ElicitationResult` hooks; `worktree.sparsePaths`; `PostCompact` hook
- **2.1.75**: Opus 4.6 1M context (Max/Team/Enterprise); `/color` command; last-modified timestamps on memory files

### Full Hook Event List (25 total as of 2.1.85)
SessionStart, UserPromptSubmit, PreToolUse, PermissionRequest, PostToolUse, PostToolUseFailure, Notification, SubagentStart, SubagentStop, TaskCreated, TaskCompleted, Stop, StopFailure, TeammateIdle, InstructionsLoaded, ConfigChange, CwdChanged, FileChanged, PreCompact, PostCompact, WorktreeCreate, WorktreeRemove, Elicitation, ElicitationResult, SessionEnd

### Hooks That Can Block
PreToolUse (via `permissionDecision: deny`), UserPromptSubmit, PermissionRequest, PostToolUse (via `decision: block` + reason), Stop, SubagentStop, TaskCreated (exit code 2), TaskCompleted (exit code 2), TeammateIdle (exit code 2), ConfigChange, WorktreeCreate

### Key Bug Fixes Relevant to CAST
- Fixed: `--mcp-config` bypassing `allowedMcpServers`/`deniedMcpServers` (v2.1.78)
- Fixed: PreToolUse hooks returning "allow" bypassing `deny` permission rules (v2.1.77)
- Fixed: Background agent task output hanging indefinitely (v2.1.81)
- Fixed: Workflow subagents failing with schema conflicts (v2.1.84)
- Fixed: Conversation history truncation on large sessions (>5MB) with subagents (v2.1.78)
- Fixed: `deny: ["mcp__servername"]` not preventing tool visibility to model (v2.1.78)

### Community Ecosystem (curated)
Source: https://github.com/hesreallyhim/awesome-claude-code (75+ projects)
- **ruflo** (ruvnet): multi-agent swarm platform with vector memory, RAG, security guardrails — https://github.com/ruvnet/ruflo
- **claudekit** (carlrannaberg): 20+ specialized subagents with auto-save checkpointing + code quality hooks
- **Trail of Bits Security Skills**: CodeQL + Semgrep-based vulnerability detection as Claude Code skills
- **parry** (vaporif): prompt injection scanner for hooks — detects attacks and data exfiltration attempts
- **AgentSys** (avifenesh): PR management, code cleanup, performance investigation, multi-agent review workflows
- **AB Method** (ayoubben18): spec-driven workflow transforming large tasks into focused incremental missions
- **cchooks** (GowayLee): Python SDK for hook development (simplifies JSON output patterns)
- **TSK** (dtormoen): Rust CLI delegating tasks to agents in sandboxed Docker environments
- **claude-code-mcp** (steipete): Claude Code as MCP server for nested agent-in-agent patterns

### Anthropic's Own Multi-Agent Guidance
Source: https://code.claude.com/docs/en/agent-teams
- Use subagents when only the result matters; agent teams when agents need to discuss and coordinate
- Competing-hypothesis debug pattern: spawn 5 teammates explicitly assigned to disprove each other
- Plan-approval gate: teammate runs in plan mode; lead approves/rejects before implementation begins
- `broadcast` to all teammates is expensive (tokens scale with team size) — use sparingly
- Team config stored at `~/.claude/teams/{team-name}/config.json`; readable by teammates for peer discovery

### Sources
- https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md
- https://code.claude.com/docs/en/agent-teams
- https://code.claude.com/docs/en/mcp
- https://code.claude.com/docs/en/hooks
- https://github.com/hesreallyhim/awesome-claude-code
- https://github.com/steipete/claude-code-mcp
- https://github.com/ruvnet/ruflo
- https://www.bannerbear.com/blog/8-best-mcp-servers-for-claude-code-developers-in-2026/
- https://claudefa.st/blog/tools/mcp-extensions/best-addons
- https://claudefa.st/blog/guide/agents/sub-agent-best-practices
- https://github.com/coleam00/claude-code-new-features-early-2026
- https://github.com/anthropics/claude-code/releases
