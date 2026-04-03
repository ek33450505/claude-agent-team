# CAST Gaps, Overlap, and Dashboard Pivot Analysis

**Date:** 2026-04-03
**Researcher:** researcher agent
**Scope:** Claude Code feature gap analysis, plan command overlap, dashboard vs TUI pivot

---

## Executive Summary

Three high-priority findings:

1. **Hook gaps are the most actionable issue.** CAST is missing handlers for `ConfigChange`,
   `PermissionDenied`, `Notification`, `CwdChanged`, `FileChanged`, `Elicitation`,
   `WorktreeCreate/Remove`, and the newer `StopFailure` matcher pattern. Several of these
   (ConfigChange, PermissionDenied) are direct observability and security wins with minimal
   effort.

2. **The plan/orchestrator pattern is not replaced by Agent Teams.** Agent Teams are
   experimental, higher-cost, and solve a different problem (peer agents communicating).
   CAST's plan → orchestrator → manifest flow is superior for structured, sequential
   automation. However, TaskCreate/TaskUpdate tools in the orchestrator could be better
   integrated with the native Agent Teams task list for dashboard visibility.

3. **The web dashboard remains the right architecture.** The React dashboard is better
   for portfolio visibility, data richness, and ease of development. A tmux-based
   complement (not replacement) is achievable with minimal effort using the existing
   statusline and existing `cast-statusline.sh`. A full TUI rewrite would destroy the
   portfolio signal.

---

## 1. Gaps Analysis

### 1a. Hook Events CAST Is Missing

CAST registers: SessionStart, UserPromptSubmit, PostToolUse, PostToolUseFailure,
InstructionsLoaded, PreToolUse (Write/Edit/Bash/AskUserQuestion), SessionEnd,
SubagentStart, SubagentStop, PreCompact, PostCompact.

Missing events from the full docs surface:

| Hook Event | Status | What It Would Enable | Priority | Effort |
|---|---|---|---|---|
| `ConfigChange` | Missing | Block unauthorized settings changes; audit trail for who changed what | High | Low |
| `PermissionDenied` | Missing | Log what auto mode blocked; surface in dashboard as "blocked operations" | High | Low |
| `Notification` | Missing | React to idle prompts and permission prompts; add CAST context to notifications | Medium | Low |
| `Stop` | Missing | Could inject "did you forget to commit?" reminder on Stop; or gate on quality checks | Medium | Medium |
| `CwdChanged` | Missing | Detect project switches mid-session; reload CAST context accordingly | Medium | Low |
| `FileChanged` | Missing | Watch cast.db, settings.json for external mutations; trigger re-sync | Low | Low |
| `WorktreeCreate` | Missing | Inject CAST worktree setup (env, symlinks) when `--worktree` used | High | Medium |
| `WorktreeRemove` | Missing | Cleanup CAST state for orphaned worktrees | Low | Low |
| `Elicitation` | Missing | Auto-handle or log MCP server elicitation requests | Low | Low |
| `TeammateIdle` | Stub only | `cast-teammate-idle-hook.sh` exists but is not wired to quality gates | Medium | Low |
| `TaskCreated` | Stub only | `cast-task-created-hook.sh` exists but is not wired to naming conventions | Medium | Low |
| `TaskCompleted` | Stub only | `cast-task-completed-hook.sh` exists but not enforcing completion criteria | Medium | Low |
| `StopFailure` matchers | Missing | Current hook is generic; could match on `rate_limit` vs `authentication_failed` for different alerts | Low | Low |

**Key gap:** `ConfigChange` is especially valuable as a security hook. CAST already enforces
settings via `managed-settings.d/` but has no runtime trap for changes made via `--settings`
or `/config` that could override CAST policy.

**Key gap:** `WorktreeCreate` is a gap because CAST uses worktrees heavily (`isolation:
worktree` on code-writer, debugger, test-writer, merge). None of the worktree lifecycle is
observed via hooks — it only shows up in SubagentStart/Stop.

### 1b. Agent Frontmatter Fields CAST Does Not Use

| Field | Status | What It Would Enable | Priority | Effort |
|---|---|---|---|---|
| `skills` (on agents) | Missing | Pre-load CAST conventions into agents at startup without CLAUDE.md overhead | High | Low |
| `mcpServers` (per-agent) | Missing | Scope GitHub MCP to only the agents that need it (commit, push, code-reviewer) | Medium | Medium |
| `hooks` (per-agent) | Missing | Agent-scoped hooks (e.g., only log security agent's PreToolUse) | Low | Low |
| `paths` (on agents) | Missing | Auto-activate code-reviewer when TypeScript files are changed | Low | Medium |
| `isolation: worktree` | Partially used | code-writer and debugger use it; test-writer, security, frontend-qa do not | Medium | Low |
| `Agent(allowed-types)` in tools | Missing | Restrict which sub-agents orchestrator can spawn (security guardrail) | Low | Low |
| `context: fork` on skills | Not used | Skills could run in isolated subagent context without spawning a full agent | Low | Low |

**Key finding on `skills` frontmatter:** The native `skills` field on agents would inject full
skill content at subagent startup. CAST currently solves this by putting conventions in agent
markdown bodies directly. The skills approach would allow decoupling: write a
`cast-conventions` skill once, reference it from multiple agents. Reduces duplication in agent
files.

### 1c. Settings CAST Does Not Configure

| Setting | Status | Why It Matters | Priority | Effort |
|---|---|---|---|---|
| `alwaysThinkingEnabled` | Missing | Could enable extended thinking for planner/orchestrator by default | Low | Low |
| `effortLevel` | Missing | Not persisted — currently set per-agent via frontmatter but not as session default | Medium | Low |
| `includeGitInstructions` | Missing | Set to `false` on agents that handle their own git (commit, push, merge) to reduce token waste | Medium | Low |
| `autoMode` classifier rules | Missing | CAST could add `environment` context lines to help auto mode make better decisions | Medium | Low |
| `outputStyle` | Missing | Could set a "Concise" style for haiku agents to keep responses short | Low | Low |
| `attribution` | Missing | CAST commits don't set attribution; could customize commit trailers | Low | Low |
| `cleanupPeriodDays` | Missing | CAST has 30-day default; explicitly setting it signals intent | Low | Low |
| `feedbackSurveyRate` | Missing | Should be `0` for CAST agent sessions to suppress survey noise | Medium | Low |
| `autoMemoryEnabled` | Missing | Could disable auto-memory in specific agent contexts to prevent contamination | Low | Low |
| `fileSuggestion` | Missing | Custom `@` autocomplete could surface CAST-specific files | Low | Low |
| `showClearContextOnPlanAccept` | Missing | Set `true` to restore the "clear context" option after plan accept | Low | Low |

**Key finding on `includeGitInstructions`:** Claude's built-in git workflow instructions
(commit/PR format) conflict with CAST conventions in commit/push/merge agents. Setting
`includeGitInstructions: false` in those agents via the `env` key would reduce confusion and
token cost.

### 1d. CLI Flags CAST Does Not Use

| Flag | Status | What It Would Enable | Priority | Effort |
|---|---|---|---|---|
| `--bare` | Missing | Faster headless agent dispatch — skip skill/hook/MCP discovery for lightweight agents | High | Low |
| `--output-format stream-json --include-hook-events` | Missing | CAST could consume hook events from agent output streams for better observability | High | Medium |
| `--max-budget-usd` | Missing | Add a cost guard to cast exec and orchestrator dispatches | Medium | Low |
| `--max-turns` | Missing | Could cap run-away agents in print mode (complements maxTurns frontmatter) | Medium | Low |
| `--append-system-prompt` | Missing | Alternative to CLAUDE.md for injecting CAST conventions in specific dispatches | Low | Low |
| `--fork-session` | Missing | When resuming orchestrator plans, fork the session to avoid corruption | Low | Low |
| `--no-session-persistence` | Missing | For ephemeral cast exec runs that shouldn't pollute session history | Low | Low |
| `--json-schema` | Missing | Could validate structured agent output against a JSON schema for contract enforcement | Medium | High |
| `--fallback-model` | Missing | Auto-fallback to Haiku when Sonnet is overloaded, for print-mode agent calls | Low | Low |
| `--from-pr` | Missing | Resume a CAST session linked to a PR — useful for cast exec on PR-based triggers | Low | Low |
| `--remote-control` | Missing | Could enable remote-triggering CAST sessions from Claude.ai | Low | Medium |

**Key finding on `--bare`:** When CAST dispatches lightweight agents (commit, push,
test-runner), those agents spend time discovering hooks, skills, MCP servers, and
auto-memory. `--bare` skips all of that. For haiku-tier agents doing simple operations,
this reduces startup latency.

**Key finding on `--output-format stream-json --include-hook-events`:** This enables a new
observability pattern — a CAST wrapper process could consume the full event stream from a
claude subprocess and feed events directly to cast.db without relying on shell hook scripts.
This is architecturally cleaner than the current multiple-script hook chain.

### 1e. Features CAST Does Not Use At All

| Feature | Status | What It Would Enable | Priority | Effort |
|---|---|---|---|---|
| Native `/batch` skill | Not integrated | Built-in parallel batch execution with per-unit worktrees and PR creation | Medium | Low |
| Auto Memory (`MEMORY.md`) | Partial | Agents use `memory: local` but don't all implement proactive MEMORY.md writes | Medium | Low |
| `.claude/rules/` path-scoped rules | Not used | Replace large CLAUDE.md blocks with path-scoped rule files | Medium | Medium |
| Agent Teams (experimental) | Not used | Peer agent communication for complex debugging scenarios | Low | High |
| `context: fork` skills | Not used | Skills could run in isolated contexts without a full agent dispatch | Low | Low |
| `claude agents` CLI command | Not integrated | cast status could use this to list active agents | Low | Low |
| HTTP hooks | Not used | Webhook-based hooks to external services (Slack, monitoring) | Low | Medium |
| Prompt hooks | Not used | Single-turn Claude evaluation hooks for policy enforcement | Low | Medium |
| Agent hooks | Not used | Subagent-with-tools hooks for complex verification tasks | Low | High |
| `PermissionRequest` hook | Not used | Custom permission approval logic (CAST security layer) | Low | Medium |
| `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` env | Not set | Gates Agent Teams — currently unused | Low | Low |
| `claude --remote` / web sessions | Not used | Remote-triggered CAST sessions | Low | High |
| Plugins system | Not used | Distributable CAST plugin for Homebrew users | Medium | High |

---

## 2. Plan Command Overlap Analysis

### What CAST's `/plan` + orchestrator does

1. `/plan` skill: writes a plan file with metadata, implementation strategy, and an
   Agent Dispatch Manifest (ADM) JSON block.
2. Orchestrator agent: reads the ADM, presents a 10-second interrupt window, then
   dispatches agents in batch order — parallel or sequential — with contract validation,
   checkpoint writing, and quality_gates logging to cast.db.
3. TaskCreate/TaskUpdate tools: orchestrator tracks batch status in the native task list.

### What Claude Code's native planning offers

| Native Feature | How It Works |
|---|---|
| `plan` permission mode | Read-only exploration mode; Claude plans but cannot write |
| Built-in `Plan` subagent | Research-only subagent used internally during plan mode |
| Agent Teams + shared task list | Teammates claim tasks from a shared list, communicate directly |
| `TaskCreate/TaskUpdate/TaskList/TaskGet` tools | Native task list, can be used by any agent |
| `/batch` bundled skill | Decompose large changes into 5–30 units, spawn one agent per unit in a worktree |

### Head-to-head comparison

| Dimension | CAST plan → orchestrator | Native Agent Teams | Native `/batch` |
|---|---|---|---|
| Structured manifest | ADM JSON with explicit agents, prompts, parallel flags | Free-form; lead decides team structure | Automatic decomposition |
| Approval gate | 10-second interrupt + user confirmation before execute | User must ask for a team; lead proposes | User approves plan before execution |
| Contract validation | Status block enforcement + quality_gates table | None | None |
| Observability | cast.db quality_gates, dispatch_decisions tables | None | GitHub PRs |
| Checkpoint/resume | File-based checkpoint + `/orchestrate resume` | No session resumption for in-process teammates | None |
| Cost | Single orchestrator session + sequential subagents | Each teammate = separate context window | N worktree sessions in parallel |
| File conflict detection | `owns_files` in ADM, orchestrator checks before parallel dispatch | None | Worktree isolation per agent |
| Stability | Mature, tested, works reliably | Experimental, known limitations | Stable |
| Communication model | One-way (agent → orchestrator) | Peer-to-peer between teammates | One-way (agent → lead) |
| Best for | Pre-planned, sequential-with-parallelism workflows | Exploratory, peer-collaborative work | Large-scale codebase changes |

### What CAST does that native cannot

- **Structured ADM format:** Explicit, reviewable JSON manifest before dispatch. Native Agent
  Teams use natural language team descriptions.
- **Contract enforcement:** Status block validation + retry logic + quality_gates logging.
  Native has no output format enforcement.
- **Checkpoint/resume:** If an orchestrator run is interrupted, it resumes from the last
  completed batch. Native teams have no session resumption.
- **cast.db integration:** Full audit trail of dispatch decisions, quality gates, agent
  token usage.
- **Cost budget:** ADM caps at 4 agents per parallel batch. Native teams can spawn
  arbitrarily many teammates.

### What native does that CAST cannot

- **Peer communication:** Agent Team teammates can message each other directly, challenge
  each other's findings, and converge on answers collaboratively. CAST agents only report
  back to the orchestrator.
- **Self-claiming tasks:** Teammates pick up unblocked tasks from the shared list without
  the orchestrator assigning them explicitly. CAST requires explicit ADM batch definitions.
- **Dynamic team size:** Native teams adapt team size based on task complexity. CAST
  requires the planner to write the manifest ahead of time.

### Recommendation

**Do not replace the plan → orchestrator flow.** It is architecturally superior for CAST's
use case: structured, audited, checkpoint-resumable execution with contract enforcement.

**Do consider three targeted integrations:**

1. **TaskCreate/TaskList**: the orchestrator already uses these tools. Expose task list
   data via the dashboard's `/plans` view so users can see real-time batch progress
   without needing cast.db queries.

2. **Enable Agent Teams for exploratory work:** Add `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`
   to settings.json env block. Use it for open-ended research and debugging where peer
   communication adds value, while keeping plan → orchestrator for execution-phase work.

3. **Native `/batch` for mass codebase changes:** The built-in `/batch` skill handles
   large-scale parallel changes (e.g., migrate all components, rename across 50 files)
   better than CAST orchestrator because it uses per-unit worktrees and opens PRs
   automatically. CAST orchestrator is better for planned feature work with defined
   agent roles.

---

## 3. Dashboard Pivot Analysis

### Current dashboard state

The claude-code-dashboard is a React 19 + Vite + Express 5 + SQLite app with 20 views:
Activity, Sessions, Analytics, Agents, Hooks, Plans, Memory, System, Token Spend, SQLite
Explorer, Live, Rules, Knowledge, and more. It reads from cast.db and filesystem paths.

### Existing TUI ecosystem for Claude Code

From the search results, these projects already exist in the ecosystem:

| Project | Type | Approach |
|---|---|---|
| `claude-dashboard` (seunggabi) | TUI | k9s-style, tmux-based session management |
| `claude-esp` | TUI | Go-based stream viewer for hidden Claude output |
| `claude-tmux` | Wrapper | tmux popup of all Claude Code instances |
| `claude-code-config` (joeyism) | TUI | Textual-based config file manager |
| `Claude Panel` | TUI | Persistent sidekick panel with context |
| `claude-canvas` | TUI | iTerm2/Apple Terminal toolkit |

The ecosystem is already producing TUI tools. The differentiation angle for CAST is the
**observability layer** (cast.db), not terminal UX.

### TUI Framework Options

| Framework | Language | Pros | Cons |
|---|---|---|---|
| **Ink** | TypeScript/React | React syntax matches existing dashboard code; component reuse possible | Limited widget set vs web; not suited for rich charts |
| **Blessed** | JavaScript/Node | Mature widget set; good for box layouts | Actively maintained fork (neo-blessed) but original abandoned |
| **Textual** | Python | CSS-like styling; rich built-in widgets; fast iteration | New language for CAST (currently Bash + Python scripts + JS) |
| **BubbleTea** | Go | Excellent for fast, reactive TUIs; production quality | New language for CAST; large rewrite |
| **tmux + bash** | Bash | Zero new dependencies; aligns with existing CAST stack | Very limited UI capabilities |

### tmux-based wrapper viability

Claude Code already has native tmux support:
- `--tmux` flag creates a tmux session for worktrees
- `--teammate-mode tmux` splits Agent Team panes
- `teammateMode` setting controls display mode

CAST already has a statusline (`cast-statusline.sh`) that shows session info. A tmux
wrapper could:
1. Run `claude` in the main pane
2. Run `watch cast status` or a new `cast-monitor` script in a side pane
3. Read from cast.db and display live agent/session data

This is achievable in ~100 lines of bash using `tmux split-window` and the existing
`cast-stats.sh` output. It would not require a new framework.

### Pros/Cons Analysis

| Approach | Pros | Cons |
|---|---|---|
| **Keep web dashboard (current)** | Portfolio-visible; rich charts (Recharts, Nivo); multi-page; shareable URLs; no new language; easy React dev | Requires separate browser window; Express server overhead; not native terminal |
| **Full TUI rewrite (Ink or Textual)** | Native terminal; closer to Claude Code workflow | Destroys existing portfolio work; no rich charts; significant rewrite cost; TUI space already crowded |
| **tmux wrapper complement** | Zero new stack; works with existing scripts; native Claude Code integration | Limited UI; only bash-based data display |
| **Ink TUI as companion (not replacement)** | Reuses React patterns; ships alongside dashboard; targets different use case | Moderate effort; two apps to maintain |

### Recommendation

**Keep the web dashboard. Add a tmux companion for in-terminal visibility.**

Rationale:
1. The web dashboard is a **portfolio differentiator** for the Anthropic job goal. A rich,
   multi-page React app with charts demonstrates full-stack engineering skill. A TUI clone
   demonstrates shell scripting.
2. The TUI ecosystem for Claude Code is **already saturated** (6+ projects found). CAST's
   moat is cast.db observability and the agent framework — not terminal UX.
3. A tmux companion is **low-effort high-value**: wrap `claude` in a tmux session with a
   cast-monitor side pane showing live agent status. This complements the dashboard without
   replacing it.
4. The dashboard already reads from `cast.db`. A tmux companion reading the same database
   gives the same data in both contexts.

**What the tmux companion should show:**
- Active agents (SubagentStart/Stop feed)
- Current session token usage
- Last 5 hook events
- cast.db agent_runs table (live tail)
- Orchestrator batch progress

**What stays in the web dashboard:**
- Historical analytics and charts
- Session playback
- Agent scorecard
- SQLite explorer
- Memory browser
- Plans review

---

## 4. Recommended Next Steps (Prioritized)

### Priority 1 — Immediate, Low Effort, High Value

1. **Add `ConfigChange` hook** — wire to `cast-tool-failure-hook.sh` pattern; block
   unauthorized config changes or log them to cast.db.

2. **Add `PermissionDenied` hook** — log all auto-mode denials to cast.db; surface in
   dashboard's Hook Health view.

3. **Add `WorktreeCreate` hook** — inject CAST environment (symlinks, env vars) into
   new worktrees automatically. Currently this is manual.

4. **Wire TeammateIdle/TaskCreated/TaskCompleted stubs** — the scripts exist but aren't
   connected to quality gates or naming conventions. Add the logic.

5. **Set `includeGitInstructions: false` for commit/push/merge agents** — reduces token
   waste and removes conflicting git instructions in those agents.

6. **Set `feedbackSurveyRate: 0`** in settings.json — CAST agent sessions should not
   trigger Anthropic's session quality survey.

### Priority 2 — Medium Effort, High Value

7. **Use `--bare` flag for haiku agents** — when cast exec dispatches commit, push, and
   test-runner agents, add `--bare` to skip full context loading. Reduces latency for
   lightweight operations.

8. **Extract `cast-conventions` skill** — move repeated CAST conventions from agent
   bodies into a shared skill file. Add `skills: [cast-conventions]` to all agents.
   DRY improvement across 16 agent files.

9. **Build tmux companion script** (`scripts/cast-tmux-session.sh`) — wrap `claude`
   in a tmux layout with a cast-monitor side pane. ~100 lines of bash. Does not require
   any new framework.

10. **Enable Agent Teams in dev sessions** — add
    `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: "1"` to settings.json env block. Use for
    exploratory debugging sessions alongside the existing plan → orchestrator flow.

### Priority 3 — Strategic, Higher Effort

11. **CAST Plugin for distribution** — package agents, skills, and hooks as a Claude Code
    plugin. This is the right distribution mechanism once the Homebrew tap matures. Plugins
    let users install CAST via `claude plugin install` instead of `brew install cast`.

12. **stream-json observability** — prototype a `cast-stream-observer.sh` that runs
    `claude -p --output-format stream-json --include-hook-events` and pipes events to
    cast.db. This eliminates the multi-script hook chain for new sessions and provides
    finer-grained event data.

13. **path-scoped rules in `.claude/rules/`** — migrate the rules/* files in the CAST
    repo to path-scoped rule files. TypeScript-specific rules only load when `.ts` files
    are open; shell-specific rules only load for `.sh` files. Reduces CLAUDE.md context
    overhead.

---

## Sources Consulted

- [Claude Code hooks documentation](https://code.claude.com/docs/en/hooks)
- [Claude Code sub-agents documentation](https://code.claude.com/docs/en/sub-agents)
- [Claude Code settings documentation](https://code.claude.com/docs/en/settings)
- [Claude Code agent teams documentation](https://code.claude.com/docs/en/agent-teams)
- [Claude Code memory documentation](https://code.claude.com/docs/en/memory)
- [Claude Code skills documentation](https://code.claude.com/docs/en/skills)
- [Claude Code CLI reference](https://code.claude.com/docs/en/cli-reference)
- [claude-dashboard TUI (seunggabi)](https://github.com/seunggabi/claude-dashboard)
- [claude-code-config TUI (joeyism)](https://github.com/joeyism/claude-code-config)
- [awesome-claude-code ecosystem list](https://github.com/hesreallyhim/awesome-claude-code)
- [Hatchet: Building a TUI is easy now](https://hatchet.run/blog/tuis-are-easy-now)
- [7 TUI libraries comparison — LogRocket](https://blog.logrocket.com/7-tui-libraries-interactive-terminal-apps/)
- Cast repo: `/Users/edkubiak/Projects/personal/claude-agent-team`
- Dashboard repo: `/Users/edkubiak/Projects/personal/claude-code-dashboard`
